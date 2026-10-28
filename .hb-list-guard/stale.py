"""Three clients like the cmux-tui servers built before #26255: each connects, asks
`_acpmux/watch` for the whole list, reads the reply, hangs up, and does it again a
second later. Runs for argv[2] seconds."""
import socket, sys, threading, time
path, secs = sys.argv[1], float(sys.argv[2])
counts = [0, 0, 0]
def client(k):
    end = time.time() + secs
    while time.time() < end:
        t = time.time()
        s = socket.socket(socket.AF_UNIX); s.connect(path)
        s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"_acpmux/watch","params":{"enabled":true}}\n')
        f = s.makefile("rb")
        while True:
            line = f.readline()
            if not line or line.startswith(b'{"id":1,'):
                break
        s.close(); counts[k] += 1
        time.sleep(max(0.0, 1.0 - (time.time() - t)))
ts = [threading.Thread(target=client, args=(k,)) for k in range(3)]
[t.start() for t in ts]; [t.join() for t in ts]
print(f"stale clients: lists read {counts}")
