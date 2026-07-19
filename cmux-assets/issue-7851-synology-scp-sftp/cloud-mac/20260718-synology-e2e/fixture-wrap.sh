#!/bin/sh
# Forced-command wrapper: pins tmux to this host's own server socket dir,
# then runs the requested command unchanged (or a login shell for
# interactive sessions).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export TMUX_TMPDIR=/Users/austinwang/Library/Caches/cmux/remote-tmux-fuzz/issue7851-sftp-off-tmux
export HOME=/Users/austinwang/Library/Caches/cmux/remote-tmux-fuzz/issue7851-sftp-off-home/run1
mkdir -p "$HOME"
exec /bin/sh -c "${SSH_ORIGINAL_COMMAND:-exec \$SHELL -l}"
