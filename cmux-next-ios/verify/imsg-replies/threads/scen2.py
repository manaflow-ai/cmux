import sys, os; sys.path.insert(0,'/tmp/imsg-parity/tools'); from run1 import *
A1="Are we still on for dinner tonight"
A2="I was thinking the Thai place on Main Street since they have that patio now and it should be really nice out tonight"
A3="Let me know by five"
B1="Yes Thai sounds perfect"; B2="Booking for seven"
def rep(target, text): hook_reply(target, text); close()
OUT=os.environ.get("OUT","/tmp/imsg-parity/s2")
os.makedirs(OUT, exist_ok=True)
relaunch()
open_chat(JA); send(A1); send(A2); send(A3)
open_chat(KB); send(B1); send(B2)
rep(B2, "Adjacent reply to my own")          # reply right under its original
shot(OUT+'/01-adjacent-own.png')
rep(A3, "Sounds good see you there")          # reply to theirs, not adjacent
shot(OUT+'/02-theirs-far.png')
rep(A3, "Want me to grab a table outside")    # second reply, right under the first
shot(OUT+'/03-second-reply.png')
open_chat(JA); rep(B1, "Great I will tell the others")   # their reply to mine
open_chat(KB); wait(1); shot(OUT+'/04-their-reply.png')
rep(A2[:24], "Patio for sure")                     # long quote
shot(OUT+'/05-long.png')
rep("Patio for sure", "Reply to a reply")     # reply to a reply
shot(OUT+'/06-reply-to-reply.png')
dumplog('x')
