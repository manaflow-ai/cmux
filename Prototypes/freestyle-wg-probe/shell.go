package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

var shellExitMarker = []byte("\x00CMUX_SHELL_EXIT\x00")
var shellResizePrefix = []byte("\x00CMUX_RESIZE\x00")

func terminalSize(fd int) (rows, cols int) {
	cols, rows, err := term.GetSize(fd)
	if err != nil || rows < 1 || cols < 1 {
		return 24, 80
	}
	return rows, cols
}

func terminalName() string {
	name := os.Getenv("TERM")
	if name == "" || strings.ContainsAny(name, " \t\r\n") {
		return "xterm-256color"
	}
	return name
}

func flushTerminalInput(fd int) error {
	return unix.IoctlSetInt(fd, unix.TIOCFLUSH, unix.TCIFLUSH)
}

func shellResizeFrame(rows, cols int) []byte {
	if rows < 1 {
		rows = 24
	}
	if cols < 1 {
		cols = 80
	}
	if rows > 65535 {
		rows = 65535
	}
	if cols > 65535 {
		cols = 65535
	}
	frame := make([]byte, len(shellResizePrefix)+4)
	copy(frame, shellResizePrefix)
	binary.BigEndian.PutUint16(frame[len(shellResizePrefix):], uint16(rows))
	binary.BigEndian.PutUint16(frame[len(shellResizePrefix)+2:], uint16(cols))
	return frame
}

func runPrivateShell(ctx context.Context, t *tunnel, ip string, port int, token string) error {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return err
	}
	dialCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	conn, err := t.net.DialContextTCPAddrPort(dialCtx, netip.AddrPortFrom(addr, uint16(port)))
	if err != nil {
		return fmt.Errorf("private TCP dial: %w", err)
	}
	defer conn.Close()
	rows, cols := terminalSize(int(os.Stdin.Fd()))
	if _, err := fmt.Fprintf(conn, "%s\n%d %d\n%s\n", token, rows, cols, terminalName()); err != nil {
		return err
	}
	oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		return fmt.Errorf("raw terminal: %w", err)
	}
	defer term.Restore(int(os.Stdin.Fd()), oldState)
	// The picker and the text fallback both read from this same TTY. Drop
	// keystrokes that were queued while the VM connection was starting so
	// picker navigation cannot become commands in the remote shell.
	_ = flushTerminalInput(int(os.Stdin.Fd()))
	var writeMu sync.Mutex
	done := make(chan error, 1)
	resizeDone := make(chan struct{})
	defer close(resizeDone)
	resizeSignals := make(chan os.Signal, 1)
	signal.Notify(resizeSignals, syscall.SIGWINCH)
	defer signal.Stop(resizeSignals)
	go func() {
		for {
			select {
			case <-resizeDone:
				return
			case <-resizeSignals:
				newRows, newCols := terminalSize(int(os.Stdin.Fd()))
				writeMu.Lock()
				_, _ = conn.Write(shellResizeFrame(newRows, newCols))
				writeMu.Unlock()
			}
		}
	}()
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, e := os.Stdin.Read(buf)
			if n > 0 {
				writeMu.Lock()
				_, _ = conn.Write(buf[:n])
				writeMu.Unlock()
			}
			if e != nil {
				break
			}
		}
		_ = conn.Close()
	}()
	go func() {
		buf := make([]byte, 32*1024)
		pending := make([]byte, 0, len(shellExitMarker))
		for {
			n, e := conn.Read(buf)
			if n > 0 {
				pending = append(pending, buf[:n]...)
				if at := bytes.Index(pending, shellExitMarker); at >= 0 {
					_, _ = os.Stdout.Write(pending[:at])
					_ = conn.Close()
					done <- nil
					return
				}
				keep := 0
				for k := 1; k < len(shellExitMarker) && k <= len(pending); k++ {
					if bytes.Equal(pending[len(pending)-k:], shellExitMarker[:k]) {
						keep = k
					}
				}
				if len(pending) > keep {
					_, _ = os.Stdout.Write(pending[:len(pending)-keep])
					pending = append(pending[:0], pending[len(pending)-keep:]...)
				}
			}
			if e != nil {
				_ = conn.Close()
				if len(pending) > 0 {
					_, _ = os.Stdout.Write(pending)
				}
				if e == io.EOF {
					done <- nil
				} else {
					done <- e
				}
				return
			}
		}
	}()
	select {
	case e := <-done:
		return e
	case <-ctx.Done():
		_ = conn.Close()
		return ctx.Err()
	}
}
