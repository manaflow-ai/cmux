// Command freestyle-wg-probe proves private TCP access without creating a
// system tunnel. It accepts the clientConfig returned by Freestyle.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type config struct {
	privateKey string
	address    []netip.Addr
	dns        []netip.Addr
	mtu        int
	publicKey  string
	psk        string
	allowed    []netip.Prefix
	endpoint   string
	keepalive  int
}

func parseConfig(path string) (config, error) {
	info, err := os.Stat(path)
	if err != nil {
		return config{}, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return config{}, errors.New("config file must be owner-only (mode 600 or stricter)")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return config{}, err
	}
	return parseConfigText(string(b))
}

func parseConfigText(text string) (config, error) {
	var c config
	var err error
	c.mtu = 1200
	section := ""
	lines := strings.Split(text, "\n")
	seenPeer := false
	for n, raw := range lines {
		line := raw
		if i := strings.IndexAny(line, ";#"); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if section != "interface" && section != "peer" {
				return c, fmt.Errorf("line %d: unsupported section %q", n+1, section)
			}
			if section == "peer" {
				if seenPeer {
					return c, fmt.Errorf("line %d: only one peer is supported", n+1)
				}
				seenPeer = true
			}
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || section == "" {
			return c, fmt.Errorf("line %d: expected key = value", n+1)
		}
		key, value := strings.ToLower(strings.TrimSpace(parts[0])), strings.TrimSpace(parts[1])
		switch section {
		case "interface":
			switch key {
			case "privatekey":
				c.privateKey, err = keyHex(value)
			case "address":
				var p netip.Prefix
				p, err = netip.ParsePrefix(value)
				if err == nil {
					c.address = append(c.address, p.Addr())
				}
			case "dns":
				for _, part := range strings.Split(value, ",") {
					var ip netip.Addr
					ip, err = netip.ParseAddr(strings.TrimSpace(part))
					if err != nil {
						break
					}
					c.dns = append(c.dns, ip)
				}
			case "mtu":
				c.mtu, err = strconv.Atoi(value)
			default:
				return c, fmt.Errorf("line %d: unsupported interface key %q", n+1, key)
			}
		case "peer":
			switch key {
			case "publickey":
				c.publicKey, err = keyHex(value)
			case "presharedkey":
				c.psk, err = keyHex(value)
			case "allowedips":
				for _, part := range strings.Split(value, ",") {
					var p netip.Prefix
					p, err = netip.ParsePrefix(strings.TrimSpace(part))
					if err != nil {
						break
					}
					c.allowed = append(c.allowed, p)
				}
			case "endpoint":
				c.endpoint = value
			case "persistentkeepalive":
				c.keepalive, err = strconv.Atoi(value)
			default:
				return c, fmt.Errorf("line %d: unsupported peer key %q", n+1, key)
			}
		}
		if err != nil {
			return c, fmt.Errorf("line %d: %w", n+1, err)
		}
	}
	if c.privateKey == "" || c.publicKey == "" || c.endpoint == "" || len(c.address) == 0 || len(c.allowed) == 0 {
		return c, errors.New("config needs PrivateKey, Address, Peer PublicKey, AllowedIPs, and Endpoint")
	}
	if c.mtu < 576 || c.mtu > 65535 {
		return c, errors.New("MTU must be between 576 and 65535")
	}
	if c.keepalive < 0 || c.keepalive > 65535 {
		return c, errors.New("PersistentKeepalive is invalid")
	}
	return c, nil
}

func keyHex(value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(raw) != 32 {
		return "", errors.New("key must be a base64-encoded 32-byte value")
	}
	return hex.EncodeToString(raw), nil
}

func containsRoute(routes []netip.Prefix, ip netip.Addr) bool {
	for _, p := range routes {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}

type tunnel struct {
	dev *device.Device
	net *netstack.Net
}

func startTunnel(c config) (*tunnel, error) {
	tun, tnet, err := netstack.CreateNetTUN(c.address, c.dns, c.mtu)
	if err != nil {
		return nil, fmt.Errorf("create userspace IP stack: %w", err)
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, ""))
	endpoint, err := net.ResolveUDPAddr("udp", c.endpoint)
	if err != nil {
		dev.Close()
		return nil, fmt.Errorf("resolve WireGuard endpoint: %w", err)
	}
	endpointIP, ok := netip.AddrFromSlice(endpoint.IP)
	if !ok {
		dev.Close()
		return nil, errors.New("WireGuard endpoint did not resolve to an IP address")
	}
	var u strings.Builder
	fmt.Fprintf(&u, "private_key=%s\npublic_key=%s\nendpoint=%s\n", c.privateKey, c.publicKey, netip.AddrPortFrom(endpointIP, uint16(endpoint.Port)))
	for _, p := range c.allowed {
		fmt.Fprintf(&u, "allowed_ip=%s\n", p)
	}
	if c.psk != "" {
		fmt.Fprintf(&u, "preshared_key=%s\n", c.psk)
	}
	if c.keepalive > 0 {
		fmt.Fprintf(&u, "persistent_keepalive_interval=%d\n", c.keepalive)
	}
	if err := dev.IpcSet(u.String()); err != nil {
		dev.Close()
		return nil, fmt.Errorf("configure WireGuard: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("start WireGuard: %w", err)
	}
	return &tunnel{dev: dev, net: tnet}, nil
}

func (t *tunnel) close() { t.dev.Close() }

func probe(ctx context.Context, t *tunnel, target string, maxBytes int64, expected string) (int64, string, string, error) {
	u, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, "", "", err
	}
	host, _, err := net.SplitHostPort(u.URL.Host)
	if err != nil {
		return 0, "", "", fmt.Errorf("target must use an IP and port: %w", err)
	}
	if _, err := netip.ParseAddr(host); err != nil {
		return 0, "", "", errors.New("target host must be a numeric IPv4 or IPv6 address")
	}
	client := &http.Client{
		Transport:     &http.Transport{DialContext: t.net.DialContext},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := client.Do(u)
	if err != nil {
		return 0, "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, resp.Status, "", fmt.Errorf("HTTP status %s", resp.Status)
	}
	h := sha256.New()
	n, err := io.CopyN(io.MultiWriter(io.Discard, h), resp.Body, maxBytes+1)
	if err != nil && !errors.Is(err, io.EOF) {
		return n, resp.Status, "", err
	}
	if n > maxBytes {
		return n, resp.Status, "", fmt.Errorf("response exceeds --max-bytes (%d)", maxBytes)
	}
	digest := hex.EncodeToString(h.Sum(nil))
	if expected != "" && !strings.EqualFold(expected, digest) {
		return n, resp.Status, digest, fmt.Errorf("sha256 mismatch: got %s", digest)
	}
	return n, resp.Status, digest, nil
}

func routeAllowed(target string, routes []netip.Prefix) error {
	host, _, err := net.SplitHostPort(target)
	if err != nil {
		return fmt.Errorf("target must be host:port: %w", err)
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return errors.New("target host must be a numeric IPv4 or IPv6 address")
	}
	if !containsRoute(routes, ip) {
		return fmt.Errorf("target %s is outside server-issued AllowedIPs", ip)
	}
	return nil
}

func runCheck(c config, target string, timeout time.Duration, maxBytes int64, expected string) (int64, string, string, error) {
	u, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		return 0, "", "", err
	}
	if err := routeAllowed(u.URL.Host, c.allowed); err != nil {
		return 0, "", "", err
	}
	t, err := startTunnel(c)
	if err != nil {
		return 0, "", "", err
	}
	defer t.close()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return probe(ctx, t, target, maxBytes, expected)
}

func chooseNetwork(vm cloudVM) (vmNetwork, bool) {
	networks := vm.VPCs
	if len(networks) == 0 {
		networks = vm.Networks
	}
	for _, n := range networks {
		if n.IPv4 != "" && (n.VPCID != "" || n.VPC != "") {
			return n, true
		}
	}
	return vmNetwork{}, false
}

func vmLabel(vm cloudVM) string {
	if vm.DisplayName != "" {
		return vm.DisplayName
	}
	if vm.Name != "" {
		return vm.Name
	}
	if vm.Slug != "" {
		return vm.Slug
	}
	return vm.ID
}

func pickVM(ctx context.Context, cloud *cloudClient) (cloudVM, error) {
	vms, err := cloud.listVMs(ctx)
	if err != nil {
		return cloudVM{}, fmt.Errorf("list VMs: %w", err)
	}
	if len(vms) == 0 {
		return cloudVM{}, errors.New("your Freestyle account has no VMs")
	}
	available := make([]cloudVM, 0, len(vms))
	for _, vm := range vms {
		if _, ok := chooseNetwork(vm); ok {
			available = append(available, vm)
		}
	}
	if len(available) == 0 {
		return cloudVM{}, errors.New("none of your VMs has a private network; attach one in Freestyle first")
	}
	if useInteractivePicker() {
		picked, err := runVMTPicker(available)
		if err == nil {
			return picked, nil
		}
		if errors.Is(err, errPickerCancelled) {
			return cloudVM{}, err
		}
		fmt.Fprintf(os.Stderr, "Interactive picker unavailable (%v); using text input.\n", err)
	}
	fmt.Println("Pick a VM:")
	for i, vm := range available {
		network, _ := chooseNetwork(vm)
		state := vm.State
		if state == "" {
			state = "unknown"
		}
		fmt.Printf("%2d  %-28s %-10s %s\n", i+1, vmLabel(vm), state, network.IPv4)
	}
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Print("VM number (or name): ")
		line, e := reader.ReadString('\n')
		if e != nil && !errors.Is(e, io.EOF) {
			return cloudVM{}, e
		}
		value := strings.TrimSpace(line)
		if value == "" && errors.Is(e, io.EOF) {
			return cloudVM{}, errors.New("input closed before a VM was selected")
		}
		if value == "" {
			continue
		}
		if i, e := strconv.Atoi(value); e == nil && i >= 1 && i <= len(available) {
			return available[i-1], nil
		}
		var match *cloudVM
		for i := range available {
			if strings.EqualFold(vmLabel(available[i]), value) || available[i].ID == value || available[i].Slug == value {
				if match != nil {
					return cloudVM{}, errors.New("more than one VM matches; use its number")
				}
				match = &available[i]
			}
		}
		if match != nil {
			return *match, nil
		}
		fmt.Println("No VM matches that input.")
	}
}

func privateKeyBase64(hexKey string) string {
	b, _ := hex.DecodeString(hexKey)
	return base64.StdEncoding.EncodeToString(b)
}

func runVMConnect(ctx context.Context, cloud *cloudClient, vm cloudVM) error {
	network, ok := chooseNetwork(vm)
	if !ok {
		return errors.New("selected VM has no private network")
	}
	vpcID := network.VPCID
	if vpcID == "" {
		vpcID = network.VPC
	}
	if network.IPv4 == "" {
		return errors.New("selected VM has no private IPv4 address")
	}
	if vm.State != "running" {
		fmt.Printf("Starting %s…\n", vmLabel(vm))
		if err := cloud.startVM(ctx, vm.ID); err != nil {
			return fmt.Errorf("start VM: %w", err)
		}
	}
	privateKey, publicKey, err := testKey()
	if err != nil {
		return err
	}
	tunnelData, err := cloud.createTunnel(ctx, privateKeyBase64(publicKey), vpcID)
	if err != nil {
		return fmt.Errorf("create temporary tunnel: %w", err)
	}
	if tunnelData.TunnelID == "" {
		tunnelData.TunnelID = tunnelData.ID
	}
	if tunnelData.TunnelID == "" {
		return errors.New("Freestyle did not return the temporary tunnel id")
	}
	cleanCtx := context.Background()
	defer func() {
		if err := cloud.deleteTunnel(cleanCtx, tunnelData.TunnelID); err != nil {
			fmt.Fprintf(os.Stderr, "Could not remove temporary tunnel %s: %v\n", tunnelData.TunnelID, err)
		} else {
			fmt.Println("Temporary tunnel removed.")
		}
	}()
	configText := strings.Replace(tunnelData.ClientConfig, "PrivateKey =", "PrivateKey = "+privateKeyBase64(privateKey), 1)
	wireConfig, err := parseConfigText(configText)
	if err != nil {
		return fmt.Errorf("read tunnel settings: %w", err)
	}
	bridge, err := startBridge(ctx, cloud, vm.ID, network.IPv4)
	if err != nil {
		return err
	}
	defer func() {
		if err := stopBridge(cleanCtx, cloud, vm.ID, bridge); err != nil {
			fmt.Fprintf(os.Stderr, "Could not stop temporary VM bridge: %v\n", err)
		}
	}()
	fw, err := cloud.createFirewall(ctx, tunnelData.TunnelID, vm.ID, bridge.port)
	if err != nil {
		return fmt.Errorf("open temporary private port: %w", err)
	}
	defer func() {
		if err := cloud.deleteFirewall(cleanCtx, fw.ID); err != nil {
			fmt.Fprintf(os.Stderr, "Could not remove temporary firewall rule: %v\n", err)
		}
	}()
	tun, err := startTunnel(wireConfig)
	if err != nil {
		return err
	}
	defer tun.close()
	fmt.Println()
	fmt.Println("Connected to", vmLabel(vm))
	fmt.Println("System VPN started by this tool: none")
	fmt.Println("OS TUN interface added: none")
	fmt.Println("OS routes added: none")
	fmt.Println("WireGuard: running inside this process only")
	fmt.Println("Existing VPNs: left running (this tool does not control them)")
	fmt.Println("Exit the shell to disconnect and remove temporary cloud resources.")
	fmt.Println()
	return runPrivateShell(ctx, tun, network.IPv4, bridge.port, bridge.token)
}

func runInteractive() error {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	fmt.Println("Freestyle private VM")
	fmt.Println("System VPN started by this tool: none")
	fmt.Println("OS routes changed by this tool: none")
	fmt.Println("WireGuard will run inside this process only.")
	fmt.Println("Existing VPNs are left running.")
	cloud, err := newCloudClient(ctx)
	if err != nil {
		return err
	}
	vm, err := pickVM(ctx, cloud)
	if err != nil {
		return err
	}
	return runVMConnect(ctx, cloud, vm)
}

func main() {
	if len(os.Args) == 1 {
		if err := runInteractive(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if os.Args[1] == "interactive" {
		if err := runInteractive(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if os.Args[1] == "selftest" {
		if err := runSelftest(); err != nil {
			fmt.Fprintln(os.Stderr, "FAIL selftest:", err)
			os.Exit(1)
		}
		fmt.Printf("PASS userspace-wireguard selftest bytes=%d\n", 1<<20)
		return
	}
	if os.Args[1] != "check" {
		fmt.Fprintln(os.Stderr, "usage: freestyle-wg-probe [interactive|selftest|check ...]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	configPath, target, timeout, maxBytes, expected := fs.String("config", "", "Freestyle clientConfig file"), fs.String("target", "", "http://IP:PORT/path (numeric private IP)"), fs.Duration("timeout", 20*time.Second, "overall request timeout"), fs.Int64("max-bytes", 64<<20, "maximum response body size"), fs.String("sha256", "", "expected response SHA-256")
	_ = fs.Parse(os.Args[2:])
	if *configPath == "" || *target == "" {
		fs.Usage()
		os.Exit(2)
	}
	if *maxBytes <= 0 || *maxBytes > 1<<30 {
		fmt.Fprintln(os.Stderr, "--max-bytes must be between 1 and 1073741824")
		os.Exit(2)
	}
	c, err := parseConfig(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}
	n, status, digest, err := runCheck(c, *target, *timeout, *maxBytes, *expected)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL bytes=%d status=%s sha256=%s: %v\n", n, status, digest, err)
		os.Exit(1)
	}
	fmt.Printf("PASS userspace-wireguard bytes=%d status=%s sha256=%s\n", n, status, digest)
}

// runSelftest starts two WireGuard devices and two gVisor TCP stacks. It is
// useful before a Freestyle resource exists: the bytes still cross the real
// WireGuard implementation, but the encrypted UDP packets stay on loopback.
func runSelftest() error {
	const selftestBytes = 1 << 20
	serverPrivate, serverPublic, err := testKey()
	if err != nil {
		return err
	}
	clientPrivate, clientPublic, err := testKey()
	if err != nil {
		return err
	}
	serverTun, serverNet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.0.0.1")}, nil, 1200)
	if err != nil {
		return err
	}
	server := device.NewDevice(serverTun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, ""))
	defer server.Close()
	if err := server.IpcSet("private_key=" + serverPrivate + "\nlisten_port=0\npublic_key=" + clientPublic + "\nallowed_ip=10.0.0.2/32\n"); err != nil {
		return err
	}
	if err := server.Up(); err != nil {
		return err
	}
	serverPort, err := ipcPort(server)
	if err != nil {
		return err
	}
	clientTun, clientNet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.0.0.2")}, nil, 1200)
	if err != nil {
		return err
	}
	client := device.NewDevice(clientTun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, ""))
	defer client.Close()
	if err := client.IpcSet("private_key=" + clientPrivate + "\nlisten_port=0\npublic_key=" + serverPublic + "\nallowed_ip=10.0.0.1/32\nendpoint=127.0.0.1:" + strconv.Itoa(serverPort) + "\n"); err != nil {
		return err
	}
	if err := client.Up(); err != nil {
		return err
	}
	listener, err := serverNet.ListenTCP(&net.TCPAddr{Port: 8080})
	if err != nil {
		return err
	}
	defer listener.Close()
	serverErr := make(chan error, 1)
	go func() {
		c, e := listener.Accept()
		if e != nil {
			serverErr <- e
			return
		}
		defer c.Close()
		buf := make([]byte, selftestBytes)
		if _, e = io.ReadFull(c, buf); e == nil {
			_, e = c.Write(buf)
			if halfCloser, ok := any(c).(interface{ CloseWrite() error }); ok {
				_ = halfCloser.CloseWrite()
			}
			time.Sleep(250 * time.Millisecond)
		}
		serverErr <- e
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := clientNet.DialContextTCPAddrPort(ctx, netip.AddrPortFrom(netip.MustParseAddr("10.0.0.1"), 8080))
	if err != nil {
		return fmt.Errorf("dial local peer: %w", err)
	}
	defer c.Close()
	payload := make([]byte, selftestBytes)
	if _, err := rand.Read(payload); err != nil {
		return err
	}
	want := sha256.Sum256(payload)
	if _, err := c.Write(payload); err != nil {
		return err
	}
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(c, got); err != nil {
		return err
	}
	if sha256.Sum256(got) != want {
		return errors.New("loopback payload changed")
	}
	select {
	case err := <-serverErr:
		if err != nil {
			return err
		}
	case <-ctx.Done():
		return ctx.Err()
	}
	return nil
}

func testKey() (private, public string, err error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", "", err
	}
	p, err := curve25519.X25519(b, curve25519.Basepoint)
	if err != nil {
		return "", "", err
	}
	return hex.EncodeToString(b), hex.EncodeToString(p), nil
}

func ipcPort(dev *device.Device) (int, error) {
	s, err := dev.IpcGet()
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(line, "listen_port=") {
			return strconv.Atoi(strings.TrimPrefix(line, "listen_port="))
		}
	}
	return 0, errors.New("WireGuard did not report a listen port")
}
