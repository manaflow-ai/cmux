// Package main builds libcmuxwg, a C archive that runs a userspace WireGuard
// device (wireguard-go) on an in-process TCP/IP stack (gVisor netstack).
//
// Neither app needs a system VPN or a Network Extension: the device sends and
// receives WireGuard UDP datagrams on an ordinary socket, and the apps reach
// each other with TCP over the tunnel. Each tunneled TCP connection is handed
// to Swift as one end of a local socketpair, so Swift reads and writes a plain
// file descriptor and never touches Go types.
//
// Every function returns a negative errno on failure.
package main

/*
#include <stdint.h>
#include <stdlib.h>

typedef void (*cmuxwg_log_fn)(void *context, int32_t level, const char *message);

static inline void cmuxwg_call_log(cmuxwg_log_fn fn, void *context, int32_t level, const char *message) {
	fn(context, level, message);
}
*/
import "C"

import (
	"time"
	"unsafe"
)

// cmuxwg_set_logger installs a log sink (nil removes it). level 0 is
// verbose, 1 is an error. The callback may run on any thread.
//
//export cmuxwg_set_logger
func cmuxwg_set_logger(fn C.cmuxwg_log_fn, context unsafe.Pointer) {
	if fn == nil {
		logSink = nil
		return
	}
	logSink = func(level int32, message string) {
		m := C.CString(message)
		C.cmuxwg_call_log(fn, context, C.int32_t(level), m)
		C.free(unsafe.Pointer(m))
	}
}

// cmuxwg_start creates and brings up a device. address is this side's
// tunnel address ("10.77.0.1"); uapi is a WireGuard UAPI set configuration
// ("private_key=<hex>\nlisten_port=N\npublic_key=...\n"). Returns a handle.
//
//export cmuxwg_start
func cmuxwg_start(address *C.char, uapi *C.char, mtu C.int32_t) C.int64_t {
	h, err := start(C.GoString(address), C.GoString(uapi), int(mtu))
	if err != nil {
		emit(1, "start: %v", err)
		return C.int64_t(errno(err))
	}
	return C.int64_t(h)
}

// cmuxwg_set applies a UAPI set operation (peers, endpoints, keys).
//
//export cmuxwg_set
func cmuxwg_set(handle C.int64_t, uapi *C.char) C.int32_t {
	if err := set(int64(handle), C.GoString(uapi)); err != nil {
		emit(1, "set: %v", err)
		return C.int32_t(errno(err))
	}
	return 0
}

// cmuxwg_get returns the UAPI get dump (listen_port, peers, last handshake,
// byte counters), or NULL. Free it with cmuxwg_free.
//
//export cmuxwg_get
func cmuxwg_get(handle C.int64_t) *C.char {
	s, err := get(int64(handle))
	if err != nil {
		return nil
	}
	return C.CString(s)
}

//export cmuxwg_free
func cmuxwg_free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

// cmuxwg_rebind reopens the UDP socket after a network change.
//
//export cmuxwg_rebind
func cmuxwg_rebind(handle C.int64_t) C.int32_t {
	if err := rebind(int64(handle)); err != nil {
		emit(1, "rebind: %v", err)
		return C.int32_t(errno(err))
	}
	return 0
}

// cmuxwg_stop closes the device and its listeners. Open connection fds see
// end of stream.
//
//export cmuxwg_stop
func cmuxwg_stop(handle C.int64_t) {
	stop(int64(handle))
}

// cmuxwg_listen opens a TCP listener on the tunnel address and returns a
// listener handle.
//
//export cmuxwg_listen
func cmuxwg_listen(handle C.int64_t, port C.int32_t) C.int64_t {
	lh, err := listen(int64(handle), int(port))
	if err != nil {
		emit(1, "listen: %v", err)
		return C.int64_t(errno(err))
	}
	return C.int64_t(lh)
}

// cmuxwg_accept blocks until a tunneled connection arrives and returns its
// fd. peer receives the remote tunnel address ("10.77.0.2:49152"). Returns
// a negative code once the listener closes.
//
//export cmuxwg_accept
func cmuxwg_accept(listener C.int64_t, peer *C.char, peerLen C.int32_t) C.int32_t {
	fd, remote, err := accept(int64(listener))
	if err != nil {
		return C.int32_t(errno(err))
	}
	if peer != nil && peerLen > 0 {
		b := unsafe.Slice((*byte)(unsafe.Pointer(peer)), int(peerLen))
		n := copy(b[:len(b)-1], remote)
		b[n] = 0
	}
	return C.int32_t(fd)
}

// cmuxwg_close_listener stops a listener; a blocked accept returns.
//
//export cmuxwg_close_listener
func cmuxwg_close_listener(listener C.int64_t) {
	closeListener(int64(listener))
}

// cmuxwg_dial opens a tunneled TCP connection to address ("10.77.0.1:7300")
// and returns its fd.
//
//export cmuxwg_dial
func cmuxwg_dial(handle C.int64_t, address *C.char, timeoutMs C.int32_t) C.int32_t {
	fd, err := dial(int64(handle), C.GoString(address), time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return C.int32_t(errno(err))
	}
	return C.int32_t(fd)
}

func main() {}
