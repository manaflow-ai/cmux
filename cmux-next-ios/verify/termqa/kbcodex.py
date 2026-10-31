# kbcodex.py OUT [launch args]: D1 scenario on the impl simulator (soft keyboard; never `axe type` on it):
# mock Codex (`codex N`, -CmuxMobileDemoCodexRows N) then 10 keyboard shows and hides, recorded for motion.py.
import subprocess, time, os, signal, sys
U="C9E42CC5-B201-48D7-89F2-944714BADF69"; out=sys.argv[1]; extra=sys.argv[2:]
env=dict(os.environ, SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH="1", DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
x=lambda *a: subprocess.run(["xcrun","simctl",*a],env=env,capture_output=True,text=True)
x("terminate",U,"dev.cmux.mobile")
D=x("get_app_container",U,"dev.cmux.mobile","data").stdout.strip()
for f in ["Documents/terminal-demo-timeline.txt"]:
    try: os.remove(os.path.join(D,f))
    except FileNotFoundError: pass
rec=subprocess.Popen(["xcrun","simctl","io",U,"recordVideo","--codec","h264","-f",out+".mp4"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
time.sleep(1.5)
t0=time.time()
x("launch",U,"dev.cmux.mobile","-CmuxMobileTerminalDemo","-CmuxMobileTerminalDemoPhases","kbcodex",*extra)
time.sleep(52)  # stimulus pacing: the demo phase runs ~48 s
rec.send_signal(signal.SIGINT); rec.wait(timeout=30)
x("terminate",U,"dev.cmux.mobile")
import shutil; shutil.copy(os.path.join(D,"Documents/terminal-demo-timeline.txt"), out+".timeline.txt")
print(out, "t0", t0)
