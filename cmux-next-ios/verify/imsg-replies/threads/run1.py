import sys; sys.path.insert(0,'/tmp/imsg-parity/tools'); from sim import *
def close():
    c = find(label='close')
    if c: tapn(c[0]); wait(1.2)
def dumplog(tag):
    subprocess.run(['xcrun','simctl','spawn',U,'notifyutil','-p','com.cmux.imsghook.dump'],capture_output=True); wait(1.5)
    r = subprocess.run(['xcrun','simctl','spawn',U,'log','show','--last','1m','--style','compact','--predicate','eventMessage CONTAINS "imsghook" OR eventMessage CONTAINS "ReplyOn"'], capture_output=True, text=True)
    print('\n'.join(l[l.find('] ')+2:][:900] for l in r.stdout.splitlines() if (' P ' in l or ' item ' in l or 'msgitem' in l or 'threadOriginator' in l or 'appendContext' in l or 'itemsFor' in l)))
if __name__ == "__main__": relaunch(); open_chat(JA); send('Hello there'); wait(1); hook_reply('Hello there','Hi back'); close()
if __name__ == "__main__": dumplog("a"); shot('/tmp/imsg-parity/t1.png')
