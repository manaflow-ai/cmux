package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"net/netip"
)

const testKeyB64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

func TestParseFreestyleConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "freestyle.conf")
	contents := `[Interface]
PrivateKey = ` + testKeyB64 + `
Address = 100.64.0.1/32
Address = fd7a:7570:6c6b::1/128
MTU = 1200

[Peer]
PublicKey = ` + testKeyB64 + `
AllowedIPs = 10.100.0.0/24, fd00::/8
Endpoint = vpn.example:51820
PersistentKeepalive = 25
`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := parseConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.address) != 2 || len(c.allowed) != 2 || c.mtu != 1200 || c.keepalive != 25 {
		t.Fatalf("unexpected config: %+v", c)
	}
	if c.endpoint != "vpn.example:51820" {
		t.Fatalf("endpoint=%q", c.endpoint)
	}
}

func TestRouteAllowedRejectsOutsideRoute(t *testing.T) {
	routes := []netip.Prefix{netip.MustParsePrefix("10.100.0.0/24")}
	if err := routeAllowed("10.100.0.10:8080", routes); err != nil {
		t.Fatal(err)
	}
	if err := routeAllowed("10.101.0.10:8080", routes); err == nil {
		t.Fatal("expected route rejection")
	}
	if err := routeAllowed("public.example:443", routes); err == nil || !strings.Contains(err.Error(), "numeric") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseConfigRejectsUnknownKey(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.conf")
	contents := `[Interface]
PrivateKey = ` + testKeyB64 + `
Address = 100.64.0.1/32
Unknown = value

[Peer]
PublicKey = ` + testKeyB64 + `
AllowedIPs = 10.100.0.0/24
Endpoint = 127.0.0.1:51820
`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := parseConfig(path); err == nil {
		t.Fatal("expected unknown key rejection")
	}
}
