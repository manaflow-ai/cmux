// cmux-chief-tailnet puts a Chief VM on its user's own tailnet as its own
// device (design: cmux-prompts logs/chief-vm-tailscale-DESIGN.md).
//
// It embeds Tailscale (tsnet), like Rex's built-in Tailscale: the VM's system
// tailscaled stays on cmux's infra tailnet, and this node answers only
// Tailscale SSH (as the user that runs it, `chief`). No other VM port is
// reachable from the user's tailnet. Default off: nothing runs until `up`.
//
//	cmux-chief-tailnet up [--name "Cloud Chief"] [--advertise-tag tag:x]   prints a login URL
//	cmux-chief-tailnet status [--json]
//	cmux-chief-tailnet down                                                  leaves the tailnet
//	cmux-chief-tailnet serve                                                 the node (systemd runs it)
//
// The user signs in through the login URL; this program never sees their
// Tailscale credentials. `--auth-key-file` exists for operators' headless tests.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"tailscale.com/cmd/tailscaled/childproc"
	_ "tailscale.com/feature/ssh"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "be-child" {
		// Tailscale SSH re-runs this binary as its session incubator, as it does tailscaled.
		if err := beChild(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "be-child:", err)
			os.Exit(1)
		}
		return
	}
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "cmux-chief-tailnet:", err)
		os.Exit(1)
	}
}

func beChild(args []string) error {
	if len(args) == 0 {
		return errors.New("missing mode")
	}
	f, ok := childproc.Code[args[0]]
	if !ok {
		return fmt.Errorf("unknown be-child mode %q", args[0])
	}
	return f(args[1:])
}

type tagList []string

func (t *tagList) String() string     { return strings.Join(*t, ",") }
func (t *tagList) Set(v string) error { *t = append(*t, v); return nil }

func defaultDir() string {
	if d := os.Getenv("CMUX_CHIEF_TAILNET_DIR"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cmux", "brains", "chief", "tailnet")
}

const usage = "usage: cmux-chief-tailnet up [--name NAME] [--hostname H] [--advertise-tag tag:x] | status [--json] | down | serve"

func run(args []string) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	verb := args[0]
	fs := flag.NewFlagSet(verb, flag.ContinueOnError)
	dir := fs.String("dir", defaultDir(), "state directory")
	asJSON := fs.Bool("json", false, "print JSON")
	switch verb {
	case "up":
		name := fs.String("name", "", "the Chief's name; the device is named after it")
		host := fs.String("hostname", "", "device name (default: from --name, else cmux-chief)")
		var tags tagList
		fs.Var(&tags, "advertise-tag", "tailnet tag (repeatable); a tagged device has no owner")
		keyFile := fs.String("auth-key-file", "", "operator tests only: one-use auth key file (deleted after use)")
		wait := fs.Duration("wait", 30*time.Second, "how long to wait for the login URL")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		return up(*dir, *name, *host, tags, *keyFile, *wait, *asJSON)
	case "status":
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		s, err := status(*dir)
		if err != nil {
			return err
		}
		return printStatus(s, *asJSON)
	case "down":
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		return down(*dir, *asJSON)
	case "serve":
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		return serve(*dir)
	default:
		return errors.New(usage)
	}
}

func printStatus(s Status, asJSON bool) error {
	if asJSON {
		b, _ := json.MarshalIndent(s, "", "  ")
		fmt.Println(string(b))
		return nil
	}
	fmt.Printf("state: %s\n", s.State)
	if s.AuthURL != "" {
		fmt.Printf("login URL: %s\n", s.AuthURL)
	}
	if s.DNSName != "" {
		fmt.Printf("device: %s (%s)\n", s.DNSName, strings.Join(s.IPs, ", "))
	}
	if s.Owner != "" {
		fmt.Printf("owner: %s\n", s.Owner)
	}
	if len(s.Tags) > 0 {
		fmt.Printf("tags: %s\n", strings.Join(s.Tags, ", "))
	}
	if s.KeyExpiry != "" {
		fmt.Printf("key expiry: %s\n", s.KeyExpiry)
	}
	if s.Hint != "" {
		fmt.Println(s.Hint)
	}
	return nil
}

func ctlClient(dir string) *http.Client {
	sock := filepath.Join(dir, "ctl.sock")
	return &http.Client{
		Timeout: 20 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", sock)
		}},
	}
}

func ctlStatus(dir string) (Status, error) {
	resp, err := ctlClient(dir).Get("http://ctl/status")
	if err != nil {
		return Status{}, err
	}
	defer resp.Body.Close()
	var s Status
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return Status{}, fmt.Errorf("node: %s", strings.TrimSpace(string(b)))
	}
	return s, json.NewDecoder(resp.Body).Decode(&s)
}

func status(dir string) (Status, error) {
	c, ok, err := readEnabled(dir)
	if err != nil {
		return Status{}, err
	}
	if !ok {
		if b, rerr := os.ReadFile(filepath.Join(dir, "serve.err")); rerr == nil && len(b) > 0 {
			return Status{State: "Failed", Hint: strings.TrimSpace(string(b))}, nil
		}
		return offStatus(), nil
	}
	s, err := ctlStatus(dir)
	if err != nil {
		if b, rerr := os.ReadFile(filepath.Join(dir, "serve.err")); rerr == nil && len(b) > 0 {
			return Status{State: "Failed", Enabled: true, Hostname: c.Hostname, Hint: strings.TrimSpace(string(b))}, nil
		}
		return Status{State: "Stopped", Enabled: true, Hostname: c.Hostname,
			Hint: "On, but the node is not running yet (it starts at boot). Run `cmux-chief-tailnet up` to start it."}, nil
	}
	return s, nil
}

func up(dir, name, host string, tags []string, keyFile string, wait time.Duration, asJSON bool) error {
	if err := validateTags(tags); err != nil {
		return err
	}
	if host == "" {
		host = deviceName(name)
	} else if deviceName(host) != host {
		return fmt.Errorf("--hostname %q is not a DNS label; try %q", host, deviceName(host))
	}
	want := Config{Name: name, Hostname: host, Tags: tags}
	if cur, ok, err := readEnabled(dir); err != nil {
		return err
	} else if ok {
		if _, err := ctlStatus(dir); err == nil && (cur.Hostname != want.Hostname || strings.Join(cur.Tags, ",") != strings.Join(want.Tags, ",")) {
			return fmt.Errorf("already on as %s; run `cmux-chief-tailnet down` first to change the name or tags", cur.Hostname)
		}
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if keyFile != "" {
		k, err := os.ReadFile(keyFile)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "authkey"), k, 0o600); err != nil {
			return err
		}
		os.Remove(keyFile)
	}
	os.Remove(filepath.Join(dir, "serve.err"))
	os.Remove(filepath.Join(dir, "enabled.refused"))
	// Writing the file is the switch: the systemd path unit starts the node.
	if err := writeEnabled(dir, want); err != nil {
		return err
	}
	deadline := time.Now().Add(wait)
	spawned := false
	var s Status
	for {
		var err error
		s, err = ctlStatus(dir)
		if err == nil && (s.AuthURL != "" || s.State == "Running" || s.State == "NeedsMachineAuth") {
			break
		}
		if err != nil && !spawned && time.Until(deadline) < wait-5*time.Second {
			// No systemd unit picked it up: run the node ourselves.
			if err := spawnServe(dir); err != nil {
				return err
			}
			spawned = true
		}
		if time.Now().After(deadline) {
			if s, err = status(dir); err != nil {
				return err
			}
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	return printStatus(s, asJSON)
}

func spawnServe(dir string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	logf, err := os.OpenFile(filepath.Join(dir, "serve.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logf.Close()
	cmd := exec.Command(self, "serve", "--dir", dir)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

func down(dir string, asJSON bool) error {
	_, ok, err := readEnabled(dir)
	if err != nil {
		return err
	}
	_, statErr := os.Stat(filepath.Join(dir, "state"))
	if !ok && errors.Is(statErr, os.ErrNotExist) {
		forget(dir)
		return printStatus(offStatus(), asJSON)
	}
	resp, err := ctlClient(dir).Post("http://ctl/down", "text/plain", nil)
	if err == nil {
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("down: %s", strings.TrimSpace(string(b)))
		}
		s := offStatus()
		s.Hint = "Removed from your tailnet. " + s.Hint
		return printStatus(s, asJSON)
	}
	// The node is not running: forget it locally. The device stays in the
	// user's admin console (offline) until its key expires or they remove it.
	if err := forget(dir); err != nil {
		return err
	}
	s := offStatus()
	s.Hint = "The node was not running, so it could not log out: its state is deleted here; remove the device in your Tailscale admin console. " + s.Hint
	return printStatus(s, asJSON)
}

func forget(dir string) error {
	os.Remove(filepath.Join(dir, "enabled"))
	os.Remove(filepath.Join(dir, "machine-id"))
	os.Remove(filepath.Join(dir, "authkey"))
	os.Remove(filepath.Join(dir, "enabled.refused"))
	os.Remove(filepath.Join(dir, "serve.err"))
	return os.RemoveAll(filepath.Join(dir, "state"))
}

func machineID() string {
	b, _ := os.ReadFile("/etc/machine-id")
	return strings.TrimSpace(string(b))
}

func serve(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	// One node per state dir; a second `serve` waits (it takes over if the first dies).
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	cfg, ok, err := readEnabled(dir)
	if err != nil || !ok {
		return err // off: exit 0
	}
	fail := func(err error) error {
		os.WriteFile(filepath.Join(dir, "serve.err"), []byte(err.Error()+"\n"), 0o600)
		return err
	}
	stored, _ := os.ReadFile(filepath.Join(dir, "machine-id"))
	if err := checkMachine(string(stored), machineID()); err != nil {
		// Not a transient failure: switch the node off (so systemd does not
		// start it again) and leave the reason for `status`.
		fail(err)
		return os.Rename(filepath.Join(dir, "enabled"), filepath.Join(dir, "enabled.refused"))
	}
	srv := &tsnet.Server{
		Dir:           filepath.Join(dir, "state"),
		Hostname:      cfg.Hostname,
		AdvertiseTags: cfg.Tags,
		Logf:          func(string, ...any) {},
		UserLogf: func(f string, a ...any) {
			fmt.Fprintf(os.Stderr, f+"\n", a...)
		},
	}
	if k, err := os.ReadFile(filepath.Join(dir, "authkey")); err == nil {
		srv.AuthKey = strings.TrimSpace(string(k))
		os.Remove(filepath.Join(dir, "authkey"))
	}
	if err := srv.Start(); err != nil {
		return fail(err)
	}
	defer srv.Close()
	lc, err := srv.LocalClient()
	if err != nil {
		return fail(err)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	if _, err := lc.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{RunSSH: true}, RunSSHSet: true}); err != nil {
		return fail(fmt.Errorf("turn on Tailscale SSH: %w", err))
	}

	sock := filepath.Join(dir, "ctl.sock")
	os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		return fail(err)
	}
	os.Chmod(sock, 0o600)
	defer os.Remove(sock)

	downed := make(chan struct{})
	mux := http.NewServeMux()
	nodeStatus := func(r *http.Request) (Status, error) {
		st, err := lc.Status(r.Context())
		if err != nil {
			return Status{}, err
		}
		p, err := lc.GetPrefs(r.Context())
		if err != nil {
			return Status{}, err
		}
		return statusFrom(st, cfg, p.RunSSH), nil
	}
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		s, err := nodeStatus(r)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(s)
	})
	mux.HandleFunc("POST /down", func(w http.ResponseWriter, r *http.Request) {
		// Logout removes the device from the user's tailnet; then forget the state.
		if err := lc.Logout(r.Context()); err != nil {
			http.Error(w, "logout: "+err.Error(), http.StatusBadGateway)
			return
		}
		os.Remove(filepath.Join(dir, "enabled")) // first, so systemd does not start it again
		fmt.Fprintln(w, "ok")
		close(downed)
	})
	hs := &http.Server{Handler: mux}
	go hs.Serve(ln)
	// Record the machine once the node is on the tailnet, so a VM copy is caught.
	go func() {
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-downed:
				return
			case <-t.C:
				if st, err := lc.StatusWithoutPeers(ctx); err == nil && st.BackendState == "Running" {
					if _, err := os.Stat(filepath.Join(dir, "machine-id")); errors.Is(err, os.ErrNotExist) {
						os.WriteFile(filepath.Join(dir, "machine-id"), []byte(machineID()+"\n"), 0o600)
					}
					return
				}
			}
		}
	}()
	select {
	case <-ctx.Done():
	case <-downed:
		time.Sleep(200 * time.Millisecond) // let the "ok" reach the caller
		hs.Close()
		srv.Close()
		return forget(dir)
	}
	hs.Close()
	return nil
}
