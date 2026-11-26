package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/views"
)

func TestDeviceNameIsASlugOfTheChiefName(t *testing.T) {
	cases := map[string]string{
		"Cloud Chief":            "cloud-chief",
		"  Lawrence's  Chief!! ": "lawrence-s-chief",
		"":                       "cmux-chief",
		"---":                    "cmux-chief",
		"Ünïcode Chief":          "n-code-chief",
		strings.Repeat("a", 80):  strings.Repeat("a", 63),
	}
	for in, want := range cases {
		if got := deviceName(in); got != want {
			t.Errorf("deviceName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTagsMustBeTailscaleTags(t *testing.T) {
	if err := validateTags([]string{"tag:chief", "tag:team-a"}); err != nil {
		t.Fatalf("good tags refused: %v", err)
	}
	for _, bad := range [][]string{{"chief"}, {"tag:"}, {"tag:Bad Tag"}, {"autogroup:member"}} {
		if err := validateTags(bad); err == nil {
			t.Errorf("validateTags(%q) accepted", bad)
		}
	}
}

func TestEnabledFileRoundTripsAndIsPrivate(t *testing.T) {
	dir := t.TempDir()
	if _, ok, err := readEnabled(dir); err != nil || ok {
		t.Fatalf("fresh dir: ok=%v err=%v, want off", ok, err)
	}
	want := Config{Name: "Cloud Chief", Hostname: "cloud-chief", Tags: []string{"tag:chief"}}
	if err := writeEnabled(dir, want); err != nil {
		t.Fatal(err)
	}
	got, ok, err := readEnabled(dir)
	if err != nil || !ok {
		t.Fatalf("after write: ok=%v err=%v", ok, err)
	}
	if got.Name != want.Name || got.Hostname != want.Hostname || len(got.Tags) != 1 || got.Tags[0] != "tag:chief" {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	fi, err := os.Stat(filepath.Join(dir, "enabled"))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("enabled mode %v, want 0600", fi.Mode().Perm())
	}
}

func TestACloneOfTheVMDoesNotReuseTheNode(t *testing.T) {
	if err := checkMachine("", "abc"); err != nil {
		t.Fatalf("no stored id (first login) refused: %v", err)
	}
	if err := checkMachine("abc\n", "abc"); err != nil {
		t.Fatalf("same machine refused: %v", err)
	}
	err := checkMachine("abc", "def")
	if err == nil || !strings.Contains(err.Error(), "down") {
		t.Fatalf("clone accepted or no down hint: %v", err)
	}
}

func TestStatusWhenOff(t *testing.T) {
	s := offStatus()
	if s.State != "Off" || s.Enabled || s.SSH {
		t.Fatalf("off status %+v", s)
	}
	if !strings.Contains(s.Hint, "up") {
		t.Fatalf("off hint %q does not say how to turn it on", s.Hint)
	}
}

func TestStatusNeedsLoginCarriesTheLoginURL(t *testing.T) {
	st := &ipnstate.Status{BackendState: "NeedsLogin", AuthURL: "https://login.tailscale.com/a/xyz"}
	s := statusFrom(st, Config{Hostname: "cloud-chief"}, true)
	if s.State != "NeedsLogin" || s.AuthURL != "https://login.tailscale.com/a/xyz" || !s.Enabled {
		t.Fatalf("status %+v", s)
	}
	if !strings.Contains(s.Hint, "auth_url") {
		t.Fatalf("hint %q", s.Hint)
	}
}

func TestStatusRunningNamesTheDeviceOwnerAndSSH(t *testing.T) {
	exp := time.Date(2027, 4, 19, 0, 0, 0, 0, time.UTC)
	st := &ipnstate.Status{
		BackendState: "Running",
		Self: &ipnstate.PeerStatus{
			PublicKey:    key.NewNode().Public(),
			DNSName:      "cloud-chief.tail1234.ts.net.",
			UserID:       7,
			TailscaleIPs: nil,
			KeyExpiry:    &exp,
		},
		CurrentTailnet: &ipnstate.TailnetStatus{Name: "user@example.com"},
		User:           map[tailcfg.UserID]tailcfg.UserProfile{7: {LoginName: "user@example.com"}},
	}
	s := statusFrom(st, Config{Hostname: "cloud-chief"}, true)
	if s.State != "Running" || s.DNSName != "cloud-chief.tail1234.ts.net" || s.Owner != "user@example.com" ||
		s.Tailnet != "user@example.com" || !s.SSH || s.AuthURL != "" || s.KeyExpiry != "2027-04-19T00:00:00Z" {
		t.Fatalf("status %+v", s)
	}
	if !strings.Contains(s.Hint, "ssh chief@cloud-chief") {
		t.Fatalf("hint %q", s.Hint)
	}
	b, _ := json.Marshal(s)
	for _, k := range []string{`"state"`, `"dns_name"`, `"owner"`, `"ssh"`} {
		if !strings.Contains(string(b), k) {
			t.Fatalf("json %s lacks %s", b, k)
		}
	}
}

func TestStatusTaggedHasNoOwner(t *testing.T) {
	tags := []string{"tag:chief"}
	st := &ipnstate.Status{BackendState: "Running", Self: &ipnstate.PeerStatus{UserID: 7, Tags: nil}}
	st.Self.Tags = viewOf(tags)
	st.User = map[tailcfg.UserID]tailcfg.UserProfile{7: {LoginName: "tagged-devices"}}
	s := statusFrom(st, Config{Hostname: "c", Tags: tags}, true)
	if s.Owner != "" || len(s.Tags) != 1 {
		t.Fatalf("tagged status %+v", s)
	}
}

func viewOf(s []string) *views.Slice[string] {
	v := views.SliceOf(s)
	return &v
}
