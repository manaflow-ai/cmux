package main

import "tailscale.com/ipn/ipnstate"

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

func deviceName(string) string                         { return "" }
func validateTags([]string) error                      { return nil }
func readEnabled(string) (Config, bool, error)         { return Config{}, true, nil }
func writeEnabled(string, Config) error                { return nil }
func checkMachine(string, string) error                { return nil }
func offStatus() Status                                { return Status{} }
func statusFrom(*ipnstate.Status, Config, bool) Status { return Status{} }
