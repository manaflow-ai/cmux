package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tailscale.com/ipn/ipnstate"
)

// Config is what `up` asks for; it is stored in the enabled file.
type Config struct {
	Name     string   `json:"name"`
	Hostname string   `json:"hostname"`
	Tags     []string `json:"tags,omitempty"`
}

// Status is what `status --json` prints.
type Status struct {
	State     string   `json:"state"`
	Enabled   bool     `json:"enabled"`
	AuthURL   string   `json:"auth_url,omitempty"`
	Hostname  string   `json:"hostname,omitempty"`
	DNSName   string   `json:"dns_name,omitempty"`
	IPs       []string `json:"ips,omitempty"`
	Tailnet   string   `json:"tailnet,omitempty"`
	Owner     string   `json:"owner,omitempty"`
	Tags      []string `json:"tags,omitempty"`
	SSH       bool     `json:"ssh"`
	KeyExpiry string   `json:"key_expiry,omitempty"`
	Hint      string   `json:"hint,omitempty"`
}

const defaultDeviceName = "cmux-chief"

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

// deviceName is the tailnet hostname for a Chief named name: a DNS label.
func deviceName(name string) string {
	s := strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if len(s) > 63 {
		s = strings.TrimRight(s[:63], "-")
	}
	if s == "" {
		return defaultDeviceName
	}
	return s
}

var tagRE = regexp.MustCompile(`^tag:[a-z0-9][a-z0-9-]*$`)

func validateTags(tags []string) error {
	for _, t := range tags {
		if !tagRE.MatchString(t) {
			return fmt.Errorf("%q is not a tailnet tag (tag:name, lower case)", t)
		}
	}
	return nil
}

// readEnabled reads dir/enabled; ok is false when the node is off.
func readEnabled(dir string) (Config, bool, error) {
	b, err := os.ReadFile(filepath.Join(dir, "enabled"))
	if errors.Is(err, os.ErrNotExist) {
		return Config{}, false, nil
	}
	if err != nil {
		return Config{}, false, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return Config{}, false, fmt.Errorf("%s/enabled: %w", dir, err)
	}
	if c.Hostname == "" {
		c.Hostname = deviceName(c.Name)
	}
	return c, true, nil
}

// writeEnabled turns the node on; the file is written whole (rename).
func writeEnabled(dir string, c Config) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, ".enabled.tmp")
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, "enabled"))
}

// checkMachine refuses a node state recorded on another machine: a VM made
// from a snapshot must not share this VM's node key.
func checkMachine(stored, current string) error {
	stored, current = strings.TrimSpace(stored), strings.TrimSpace(current)
	if stored == "" || stored == current {
		return nil
	}
	return errors.New("the tailnet node state was made on another machine (this VM is a copy); run `cmux-chief-tailnet down`, then `up` to add this VM as a new device")
}

func offStatus() Status {
	return Status{State: "Off", Hint: "Off. Run `cmux-chief-tailnet up` to add this Chief VM to your tailnet; it prints a login URL."}
}

func statusFrom(st *ipnstate.Status, c Config, ssh bool) Status {
	s := Status{State: st.BackendState, Enabled: true, Hostname: c.Hostname, SSH: ssh, AuthURL: st.AuthURL}
	if st.CurrentTailnet != nil {
		s.Tailnet = st.CurrentTailnet.Name
	}
	if self := st.Self; self != nil {
		s.DNSName = strings.TrimSuffix(self.DNSName, ".")
		for _, ip := range self.TailscaleIPs {
			s.IPs = append(s.IPs, ip.String())
		}
		if self.Tags != nil && self.Tags.Len() > 0 {
			s.Tags = self.Tags.AsSlice()
		} else if u, ok := st.User[self.UserID]; ok {
			s.Owner = u.LoginName
		}
		if self.KeyExpiry != nil {
			s.KeyExpiry = self.KeyExpiry.UTC().Format(time.RFC3339)
		}
	}
	switch {
	case s.AuthURL != "":
		s.Hint = "Open auth_url, sign in to your tailnet and approve the device."
	case s.State == "Running":
		host := s.Hostname
		if s.DNSName != "" {
			host = strings.SplitN(s.DNSName, ".", 2)[0]
		}
		s.Hint = fmt.Sprintf("On your tailnet as %s. Connect with `ssh chief@%s` (Tailscale SSH; your tailnet's SSH policy decides who may). `cmux-chief-tailnet down` removes it.", host, host)
	case s.State == "NeedsMachineAuth":
		s.Hint = "Waiting for a tailnet admin to approve the device in the admin console."
	default:
		s.Hint = "Starting; run status again in a few seconds."
	}
	return s
}
