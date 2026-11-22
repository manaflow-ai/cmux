# Seeds conversation-sim (port 4871) "empty" chat like the matching scen*.py Messages scene.
source "$(dirname "$0")/seedlib.sh"
k "Are we still on for dinner tonight"; k "Let me know by five"
a "Yes Thai sounds perfect"; k "Great" 0; a "Booking for seven"
a "Sounds good" 3; k "Perfect see you" 4; a "Running late"
a "Yes we are" 7; a "Table for four" 3
