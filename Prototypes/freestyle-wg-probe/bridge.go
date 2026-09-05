package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// This is a temporary, in-memory shell bridge. It is copied to the VM only as
// a command, listens on the VM's private NIC, accepts one authenticated
// terminal session, and exits.
const bridgePython = `import fcntl,json,os,pty,selectors,socket,struct,sys,termios,time
token=sys.argv[1]; bind_ip=sys.argv[2]
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind((bind_ip,0)); s.listen(1); s.settimeout(90)
print(json.dumps({'ready':True,'port':s.getsockname()[1]}),flush=True)
pid=None; fd=None; c=None
resize_prefix=b'\x00CMUX_RESIZE\x00'
def set_size(rows,cols):
    if fd is not None:
        fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
def write_all(target,data):
    view=memoryview(data)
    while view:
        n=os.write(target,view)
        view=view[n:]
def relay_input(data,pending):
    pending+=data
    while True:
        at=pending.find(resize_prefix)
        if at<0:
            keep=0
            for n in range(1,min(len(pending),len(resize_prefix)-1)+1):
                if pending[-n:]==resize_prefix[:n]: keep=n
            if len(pending)>keep:
                write_all(fd,pending[:-keep] if keep else pending)
                pending=pending[-keep:] if keep else b''
            return pending
        if at:
            write_all(fd,pending[:at]); pending=pending[at:]
        frame_len=len(resize_prefix)+4
        if len(pending)<frame_len: return pending
        rows,cols=struct.unpack('>HH',pending[len(resize_prefix):frame_len])
        set_size(rows,cols)
        pending=pending[frame_len:]
try: c,_=s.accept()
except Exception: s.close(); raise SystemExit
s.close(); c.settimeout(10)
try:
    handshake=b''
    while handshake.count(b'\n')<3 and len(handshake)<320:
        part=c.recv(320-len(handshake))
        if not part: raise SystemExit
        handshake+=part
    if handshake.count(b'\n')<3: raise SystemExit
    line,dimensions,term_name,pending=handshake.split(b'\n',3)
    if line.decode('ascii','strict')!=token: raise SystemExit
    try: rows,cols=[int(value) for value in dimensions.split()]
    except Exception: raise SystemExit
    pid,fd=pty.fork()
    if pid==0:
        os.environ['TERM']=term_name.decode('ascii','strict')
        sh=os.environ.get('SHELL','/bin/sh')
        os.execv(sh,[sh,'-l'])
    set_size(rows,cols)
    c.setblocking(False); os.set_blocking(fd,False); q=selectors.DefaultSelector(); q.register(c,selectors.EVENT_READ); q.register(fd,selectors.EVENT_READ)
    pending=relay_input(b'',pending)
    end=time.monotonic()+1800
    while time.monotonic()<end:
        for key,_ in q.select(0.25):
            try:
                if key.fileobj is c:
                    b=c.recv(65536)
                    if not b: raise SystemExit
                    pending=relay_input(b,pending)
                else:
                    b=os.read(fd,65536)
                    if not b:
                        try: c.sendall(b'\x00CMUX_SHELL_EXIT\x00')
                        except Exception: pass
                        raise SystemExit
                    c.sendall(b)
            except (BrokenPipeError,ConnectionResetError,OSError) as error:
                if key.fileobj == fd and getattr(error,'errno',None)==5:
                    try: c.sendall(b'\x00CMUX_SHELL_EXIT\x00')
                    except Exception: pass
                raise SystemExit
        done,status=os.waitpid(pid,os.WNOHANG)
        if done:
            try: c.sendall(b'\x00CMUX_SHELL_EXIT\x00')
            except Exception: pass
            raise SystemExit
finally:
    try: os.killpg(pid,15)
    except Exception: pass
    try: os.close(fd)
    except Exception: pass
    try: c.close()
    except Exception: pass
`

type bridgeInfo struct {
	pid           int
	port          int
	token, marker string
}

func randomToken() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func startBridge(ctx context.Context, cloud *cloudClient, vmID, bindIP string) (bridgeInfo, error) {
	token, err := randomToken()
	if err != nil {
		return bridgeInfo{}, err
	}
	marker := "/tmp/cmux-wg-" + token + ".ready"
	script := base64.StdEncoding.EncodeToString([]byte(bridgePython))
	command := fmt.Sprintf("rm -f %s; nohup python3 -c 'import base64;exec(base64.b64decode(\"%s\"))' %s %s >%s 2>&1 </dev/null & echo $!", marker, script, token, bindIP, marker)
	out, err := cloud.exec(ctx, vmID, command)
	if err != nil {
		return bridgeInfo{}, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(out))
	if err != nil {
		return bridgeInfo{}, fmt.Errorf("remote bridge did not return a process id: %w", err)
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			_, _ = cloud.exec(context.Background(), vmID, fmt.Sprintf("kill -TERM %d 2>/dev/null || true; rm -f %s", pid, marker))
			return bridgeInfo{}, ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
		ready, e := cloud.exec(ctx, vmID, "cat "+marker)
		if e != nil {
			continue
		}
		var result struct {
			Ready bool `json:"ready"`
			Port  int  `json:"port"`
		}
		if json.Unmarshal([]byte(strings.TrimSpace(ready)), &result) == nil && result.Ready && result.Port > 0 {
			return bridgeInfo{pid: pid, port: result.Port, token: token, marker: marker}, nil
		}
	}
	_, _ = cloud.exec(context.Background(), vmID, fmt.Sprintf("kill -TERM %d 2>/dev/null || true; rm -f %s", pid, marker))
	return bridgeInfo{}, errors.New("timed out waiting for the VM's temporary bridge")
}

func stopBridge(ctx context.Context, cloud *cloudClient, vmID string, bridge bridgeInfo) error {
	_, err := cloud.exec(ctx, vmID, fmt.Sprintf("kill -TERM %d 2>/dev/null || true; rm -f %s", bridge.pid, bridge.marker))
	return err
}
