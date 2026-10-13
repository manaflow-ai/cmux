package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/crypto/curve25519"
)

func keypair(t *testing.T) (priv, pub string) {
	t.Helper()
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		t.Fatal(err)
	}
	k[0] &= 248
	k[31] = (k[31] & 127) | 64
	p, err := curve25519.X25519(k, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(k), hex.EncodeToString(p)
}

func listenPort(t *testing.T, h int64) string {
	t.Helper()
	dump, err := get(h)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(dump, "\n") {
		if v, ok := strings.CutPrefix(line, "listen_port="); ok {
			return v
		}
	}
	t.Fatalf("no listen_port in %q", dump)
	return ""
}

// TestTunnelCarriesTCPBothWays brings up a host and a phone device on
// loopback, opens a tunneled connection from the phone, and checks bytes
// cross in both directions, including a payload far above one window.
func TestTunnelCarriesTCPBothWays(t *testing.T) {
	hostPriv, hostPub := keypair(t)
	phonePriv, phonePub := keypair(t)
	psk := strings.Repeat("ab", 32)

	host, err := start("10.77.0.1", fmt.Sprintf("private_key=%s\nlisten_port=0\npublic_key=%s\npreshared_key=%s\nallowed_ip=10.77.0.2/32\n", hostPriv, phonePub, psk), 0)
	if err != nil {
		t.Fatal(err)
	}
	defer stop(host)
	port := listenPort(t, host)

	phone, err := start("10.77.0.2", fmt.Sprintf("private_key=%s\npublic_key=%s\npreshared_key=%s\nendpoint=127.0.0.1:%s\nallowed_ip=10.77.0.1/32\npersistent_keepalive_interval=25\n", phonePriv, hostPub, psk, port), 0)
	if err != nil {
		t.Fatal(err)
	}
	defer stop(phone)

	ln, err := listen(host, 7300)
	if err != nil {
		t.Fatal(err)
	}
	type accepted struct {
		fd   int
		peer string
		err  error
	}
	got := make(chan accepted, 1)
	go func() {
		fd, peer, err := accept(ln)
		got <- accepted{fd, peer, err}
	}()

	cfd, err := dial(phone, "10.77.0.1:7300", 10*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	a := <-got
	if a.err != nil {
		t.Fatalf("accept: %v", a.err)
	}
	if !strings.HasPrefix(a.peer, "10.77.0.2:") {
		t.Fatalf("peer = %q", a.peer)
	}
	client := os.NewFile(uintptr(cfd), "client")
	server := os.NewFile(uintptr(a.fd), "server")
	defer client.Close()
	defer server.Close()

	if _, err := client.Write([]byte("{\"cmd\":\"identify\"}\n")); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(server).ReadString('\n')
	if err != nil || line != "{\"cmd\":\"identify\"}\n" {
		t.Fatalf("server read %q, %v", line, err)
	}

	big := make([]byte, 8<<20)
	rand.Read(big)
	go func() {
		server.Write(big)
		server.Close()
	}()
	back, err := io.ReadAll(client)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(back, big) {
		t.Fatalf("payload mismatch: got %d bytes", len(back))
	}
}

// TestUnknownPeerCannotConnect checks cryptokey routing: a phone whose key
// the host never added gets no connection.
func TestUnknownPeerCannotConnect(t *testing.T) {
	hostPriv, hostPub := keypair(t)
	_, knownPub := keypair(t)
	strangerPriv, _ := keypair(t)

	host, err := start("10.77.0.1", fmt.Sprintf("private_key=%s\nlisten_port=0\npublic_key=%s\nallowed_ip=10.77.0.2/32\n", hostPriv, knownPub), 0)
	if err != nil {
		t.Fatal(err)
	}
	defer stop(host)
	port := listenPort(t, host)
	if _, err := listen(host, 7300); err != nil {
		t.Fatal(err)
	}

	stranger, err := start("10.77.0.2", fmt.Sprintf("private_key=%s\npublic_key=%s\nendpoint=127.0.0.1:%s\nallowed_ip=10.77.0.1/32\n", strangerPriv, hostPub, port), 0)
	if err != nil {
		t.Fatal(err)
	}
	defer stop(stranger)

	if fd, err := dial(stranger, "10.77.0.1:7300", 2*time.Second); err == nil {
		syscall.Close(fd)
		t.Fatal("stranger connected")
	} else if err != syscall.ETIMEDOUT {
		t.Fatalf("err = %v, want ETIMEDOUT", err)
	}
}
