// Package tunnel runs userspace WireGuard devices on gVisor netstack and
// hands tunneled TCP connections out as socketpair file descriptors.
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// tunnel is one userspace WireGuard device with its own TCP/IP stack.
type tunnel struct {
	dev *device.Device
	net *netstack.Net

	mu  sync.Mutex
	lns map[int64]net.Listener
}

// registry maps the integer handles C callers hold to Go objects.
type registry struct {
	mu        sync.Mutex
	next      int64
	tunnels   map[int64]*tunnel
	listeners map[int64]*tunnel
}

var handles = &registry{next: 1, tunnels: map[int64]*tunnel{}, listeners: map[int64]*tunnel{}}

// logSink receives device and bridge log lines. level 0 = verbose, 1 = error.
var LogSink func(level int32, message string)

// Emit sends one formatted line to LogSink.
func Emit(level int32, format string, args ...any) {
	if sink := LogSink; sink != nil {
		sink(level, fmt.Sprintf(format, args...))
	}
}

func (r *registry) tunnel(handle int64) *tunnel {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tunnels[handle]
}

func (r *registry) listener(handle int64) (*tunnel, net.Listener) {
	r.mu.Lock()
	t := r.listeners[handle]
	r.mu.Unlock()
	if t == nil {
		return nil, nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t, t.lns[handle]
}

func (r *registry) add(t *tunnel) int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.next
	r.next++
	r.tunnels[h] = t
	return h
}

// start brings up a device whose tunnel address is address. uapi is the
// WireGuard UAPI set configuration. mtu <= 0 picks 1280, which fits every
// common underlay including cellular.
func Start(address, uapi string, mtu int) (int64, error) {
	addr, err := netip.ParseAddr(address)
	if err != nil {
		return 0, fmt.Errorf("tunnel address: %w", syscall.EINVAL)
	}
	if mtu <= 0 {
		mtu = 1280
	}
	tdev, tnet, err := netstack.CreateNetTUN([]netip.Addr{addr}, nil, mtu)
	if err != nil {
		return 0, fmt.Errorf("netstack: %v: %w", err, syscall.EIO)
	}
	logger := &device.Logger{
		Verbosef: func(format string, args ...any) { Emit(0, format, args...) },
		Errorf:   func(format string, args ...any) { Emit(1, format, args...) },
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), logger)
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		return 0, fmt.Errorf("uapi: %v: %w", err, syscall.EINVAL)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return 0, fmt.Errorf("up: %v: %w", err, syscall.EIO)
	}
	return handles.add(&tunnel{dev: dev, net: tnet, lns: map[int64]net.Listener{}}), nil
}

func Set(handle int64, uapi string) error {
	t := handles.tunnel(handle)
	if t == nil {
		return syscall.EBADF
	}
	if err := t.dev.IpcSet(uapi); err != nil {
		return fmt.Errorf("uapi: %v: %w", err, syscall.EINVAL)
	}
	return nil
}

func Get(handle int64) (string, error) {
	t := handles.tunnel(handle)
	if t == nil {
		return "", syscall.EBADF
	}
	return t.dev.IpcGet()
}

func Rebind(handle int64) error {
	t := handles.tunnel(handle)
	if t == nil {
		return syscall.EBADF
	}
	return t.dev.BindUpdate()
}

func Stop(handle int64) {
	handles.mu.Lock()
	t := handles.tunnels[handle]
	delete(handles.tunnels, handle)
	for lh, owner := range handles.listeners {
		if owner == t {
			delete(handles.listeners, lh)
		}
	}
	handles.mu.Unlock()
	if t == nil {
		return
	}
	t.mu.Lock()
	for _, ln := range t.lns {
		ln.Close()
	}
	t.lns = map[int64]net.Listener{}
	t.mu.Unlock()
	t.dev.Close()
}

func Listen(handle int64, port int) (int64, error) {
	t := handles.tunnel(handle)
	if t == nil {
		return 0, syscall.EBADF
	}
	ln, err := t.net.ListenTCP(&net.TCPAddr{Port: port})
	if err != nil {
		return 0, fmt.Errorf("listen: %v: %w", err, syscall.EADDRINUSE)
	}
	handles.mu.Lock()
	lh := handles.next
	handles.next++
	handles.listeners[lh] = t
	handles.mu.Unlock()
	t.mu.Lock()
	t.lns[lh] = ln
	t.mu.Unlock()
	return lh, nil
}

// accept waits for the next tunneled connection and returns a socket fd for
// it plus the remote tunnel address.
func Accept(listener int64) (int, string, error) {
	_, ln := handles.listener(listener)
	if ln == nil {
		return -1, "", syscall.EBADF
	}
	c, err := ln.Accept()
	if err != nil {
		return -1, "", syscall.ECONNABORTED
	}
	fd, err := splice(c)
	if err != nil {
		c.Close()
		return -1, "", syscall.EMFILE
	}
	return fd, c.RemoteAddr().String(), nil
}

func CloseListener(listener int64) {
	handles.mu.Lock()
	t := handles.listeners[listener]
	delete(handles.listeners, listener)
	handles.mu.Unlock()
	if t == nil {
		return
	}
	t.mu.Lock()
	ln := t.lns[listener]
	delete(t.lns, listener)
	t.mu.Unlock()
	if ln != nil {
		ln.Close()
	}
}

func Dial(handle int64, address string, timeout time.Duration) (int, error) {
	t := handles.tunnel(handle)
	if t == nil {
		return -1, syscall.EBADF
	}
	ap, err := netip.ParseAddrPort(address)
	if err != nil {
		return -1, syscall.EINVAL
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c, err := t.net.DialContextTCPAddrPort(ctx, ap)
	if err != nil {
		Emit(0, "dial %v: %v", ap, err)
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return -1, syscall.ETIMEDOUT
		}
		return -1, syscall.ECONNREFUSED
	}
	fd, err := splice(c)
	if err != nil {
		c.Close()
		return -1, syscall.EMFILE
	}
	return fd, nil
}

// splice connects c to one end of a new socketpair and returns the other
// end. EOF from the caller half-closes the tunneled connection; EOF from the
// peer closes the caller's end.
func splice(c net.Conn) (int, error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		return -1, err
	}
	syscall.CloseOnExec(fds[0])
	syscall.CloseOnExec(fds[1])
	// Darwin raises SIGPIPE on a write to a closed socket; the caller's end
	// must report EPIPE instead.
	syscall.SetsockoptInt(fds[1], syscall.SOL_SOCKET, syscall.SO_NOSIGPIPE, 1)
	syscall.SetsockoptInt(fds[0], syscall.SOL_SOCKET, syscall.SO_NOSIGPIPE, 1)
	// Non-blocking, so the runtime poller owns it: Close then interrupts a
	// pending Read. A blocking fd would keep the read (and the fd) alive,
	// and the caller would never see end of stream.
	if err := syscall.SetNonblock(fds[0], true); err != nil {
		syscall.Close(fds[0])
		syscall.Close(fds[1])
		return -1, err
	}
	local := os.NewFile(uintptr(fds[0]), "cmuxwg-splice")
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			local.Close()
			c.Close()
		})
	}
	go func() {
		io.Copy(c, local)
		if tc, ok := c.(interface{ CloseWrite() error }); ok {
			tc.CloseWrite()
		} else {
			closeBoth()
		}
	}()
	go func() {
		io.Copy(local, c)
		closeBoth()
	}()
	return fds[1], nil
}

// errno maps an error to a negative errno for the C ABI.
func Errno(err error) int64 {
	var e syscall.Errno
	if errors.As(err, &e) {
		return -int64(e)
	}
	return -int64(syscall.EIO)
}
