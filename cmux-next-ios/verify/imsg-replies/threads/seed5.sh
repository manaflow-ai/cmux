# Seeds conversation-sim (port 4871) "empty" chat like the matching scen*.py Messages scene.
source "$(dirname "$0")/seedlib.sh"
k "Are we still on for dinner tonight"; k "Let me know by five"
a "Yes Thai sounds perfect"; a "Booking for seven"
a "Adjacent reply to my own" 0; a "Sounds good" 3; a "Want me to grab a table outside" 4
k "Perfect see you" 5; a "Done" 6; a "Running late"; k "Thanks" 6
