// Command fakephone plays the iPhone side of WireGuard pairing against a
// running cmux-next Mac app, for end-to-end checks without a phone:
//
//	fakephone 'cmux-next://pair#...'
//
// It pairs with the invitation's one-time key, reconnects with its own
// permanent key, and sends cmux-tui requests over the daemon lane: identify,
// list-workspaces, a command the phone allowlist refuses, and (with -type) a
// line typed into a new terminal whose output it reads back.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/manaflow-ai/cmux/cmuxwg/tunnel"
	"golang.org/x/crypto/curve25519"
)

type invitation struct {
	Version          int      `json:"v"`
	HostName         string   `json:"n"`
	HostID           string   `json:"id"`
	HostKey          string   `json:"hk"`
	Endpoints        []string `json:"ep"`
	BootstrapKey     string   `json:"bk"`
	BootstrapAddress string   `json:"ba"`
	PresharedKey     string   `json:"psk"`
	HostAddress      string   `json:"ha"`
	ExpiresAt        float64  `json:"exp"`
}

type enrollmentResponse struct {
	OK           bool   `json:"ok"`
	Error        string `json:"error"`
	Address      string `json:"address"`
	PresharedKey string `json:"presharedKey"`
	DeviceID     string `json:"deviceID"`
}

func main() {
	typeText := flag.String("type", "", "create a terminal, type this line, and wait for it in the output")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: fakephone [-type text] 'cmux-next://pair#...'")
		os.Exit(2)
	}
	if os.Getenv("CMUX_WG_LOG_STDERR") == "1" {
		tunnel.LogSink = func(level int32, message string) { fmt.Fprintln(os.Stderr, "cmuxwg:", message) }
	}
	inv := parse(flag.Arg(0))
	fmt.Printf("invitation from %q, endpoints %v, expires %s\n", inv.HostName, inv.Endpoints,
		time.Unix(int64(inv.ExpiresAt), 0).Format(time.Kitchen))

	permanent, permanentPub := keypair()
	resp, endpoint := enroll(inv, permanentPub)
	fmt.Printf("paired: address %s, device %s, via %s\n", resp.Address, resp.DeviceID, endpoint)

	h := must(tunnel.Start(resp.Address, fmt.Sprintf(
		"private_key=%s\npublic_key=%s\npreshared_key=%s\nendpoint=%s\nallowed_ip=%s/32\npersistent_keepalive_interval=25\n",
		hex.EncodeToString(permanent), b64hex(inv.HostKey), b64hex(resp.PresharedKey), endpoint, inv.HostAddress), 0))
	defer tunnel.Stop(h)
	fd := must(tunnel.Dial(h, inv.HostAddress+":7300", 10*time.Second))
	lane := os.NewFile(uintptr(fd), "lane")
	defer lane.Close()
	reader := bufio.NewReader(lane)

	call := func(request string) map[string]any {
		fmt.Fprintln(lane, request)
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				fail("daemon lane closed: %v", err)
			}
			var out map[string]any
			json.Unmarshal([]byte(line), &out)
			if _, isEvent := out["event"]; !isEvent {
				return out
			}
		}
	}
	identify := call(`{"id":1,"cmd":"identify"}`)
	data, _ := identify["data"].(map[string]any)
	fmt.Printf("identify: ok=%v app=%v protocol=%v session=%v\n", identify["ok"], data["app"], data["protocol"], data["session"])
	list := call(`{"id":2,"cmd":"list-workspaces"}`)
	tree, _ := list["data"].(map[string]any)
	workspaces, _ := tree["workspaces"].([]any)
	fmt.Printf("list-workspaces: ok=%v, %d workspace(s)\n", list["ok"], len(workspaces))
	refused := call(`{"id":3,"cmd":"shutdown-daemon"}`)
	fmt.Printf("shutdown-daemon (must be refused): ok=%v error_code=%v\n", refused["ok"], refused["error_code"])
	if refused["ok"] != false || refused["error_code"] != "forbidden" {
		fail("policy did not refuse shutdown-daemon")
	}

	if *typeText != "" {
		created := call(`{"id":4,"cmd":"new-workspace","name":"from-fakephone","cols":80,"rows":24}`)
		cdata, _ := created["data"].(map[string]any)
		surface := cdata["surface"]
		fmt.Printf("new-workspace: ok=%v surface=%v\n", created["ok"], surface)
		fmt.Fprintf(lane, `{"id":5,"cmd":"attach-surface","surface":%v,"cols":80,"rows":24}`+"\n", surface)
		fmt.Fprintf(lane, `{"id":6,"cmd":"send","surface":%v,"text":%q}`+"\n", surface, *typeText+"\r")
		deadline := time.Now().Add(15 * time.Second)
		var seen strings.Builder
		for time.Now().Before(deadline) {
			line, err := reader.ReadString('\n')
			if err != nil {
				break
			}
			var ev map[string]any
			json.Unmarshal([]byte(line), &ev)
			if ev["event"] == "output" || ev["event"] == "vt-state" {
				raw, _ := base64.StdEncoding.DecodeString(fmt.Sprint(ev["data"]))
				seen.Write(raw)
				if strings.Count(seen.String(), *typeText) >= 2 {
					fmt.Printf("terminal echoed %q through the tunnel\n", *typeText)
					return
				}
			}
		}
		fail("did not see %q in the terminal output", *typeText)
	}
}

func enroll(inv invitation, permanentPub []byte) (enrollmentResponse, string) {
	for _, endpoint := range inv.Endpoints {
		h := must(tunnel.Start(inv.BootstrapAddress, fmt.Sprintf(
			"private_key=%s\npublic_key=%s\npreshared_key=%s\nendpoint=%s\nallowed_ip=%s/32\n",
			b64hex(inv.BootstrapKey), b64hex(inv.HostKey), b64hex(inv.PresharedKey), endpoint, inv.HostAddress), 0))
		fd, err := tunnel.Dial(h, inv.HostAddress+":7301", 6*time.Second)
		if err != nil {
			fmt.Printf("  %s: %v\n", endpoint, err)
			tunnel.Stop(h)
			continue
		}
		conn := os.NewFile(uintptr(fd), "enroll")
		request, _ := json.Marshal(map[string]string{
			"publicKey": base64.StdEncoding.EncodeToString(permanentPub), "deviceName": "fakephone", "deviceModel": "CLI",
		})
		conn.Write(append(request, '\n'))
		line, err := bufio.NewReader(conn).ReadString('\n')
		conn.Close()
		tunnel.Stop(h)
		if err != nil {
			fail("enrollment answer: %v", err)
		}
		var resp enrollmentResponse
		json.Unmarshal([]byte(line), &resp)
		if !resp.OK {
			fail("Mac refused: %s", resp.Error)
		}
		return resp, endpoint
	}
	fail("no endpoint answered")
	return enrollmentResponse{}, ""
}

func parse(link string) invitation {
	_, fragment, ok := strings.Cut(strings.TrimSpace(link), "#")
	if !ok || !strings.HasPrefix(link, "cmux-next://pair") {
		fail("not a pairing link")
	}
	raw, err := base64.RawURLEncoding.DecodeString(fragment)
	if err != nil {
		fail("bad link payload: %v", err)
	}
	var inv invitation
	if err := json.Unmarshal(raw, &inv); err != nil {
		fail("bad invitation: %v", err)
	}
	return inv
}

func keypair() (priv, pub []byte) {
	priv = make([]byte, 32)
	rand.Read(priv)
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, _ = curve25519.X25519(priv, curve25519.Basepoint)
	return
}

func b64hex(s string) string {
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(raw) != 32 {
		fail("bad key %q", s)
	}
	return hex.EncodeToString(raw)
}

func must[T any](v T, err error) T {
	if err != nil {
		if errno, ok := err.(syscall.Errno); ok {
			fail("%v (errno %d)", err, int(errno))
		}
		fail("%v", err)
	}
	return v
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "fakephone: "+format+"\n", args...)
	os.Exit(1)
}
