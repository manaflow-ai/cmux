#!/bin/sh
# Minimal cmux Dock extension: shows the injected extension context and ticks
# a clock. Link it for development with:
#   cmux extension link Examples/extensions/hello-tui   (CLI lands in phase 2)
# or Settings → Extensions once it is published with the cmux-extension topic.
printf '\033[2J\033[H'
echo "hello from a cmux Dock extension"
echo
echo "CMUX_EXTENSION_ID         = ${CMUX_EXTENSION_ID:-<unset>}"
echo "CMUX_EXTENSION_PANE_ID    = ${CMUX_EXTENSION_PANE_ID:-<unset>}"
echo "CMUX_EXTENSION_ROOT       = ${CMUX_EXTENSION_ROOT:-<unset>}"
echo "CMUX_EXTENSION_CONFIG_DIR = ${CMUX_EXTENSION_CONFIG_DIR:-<unset>}"
echo "CMUX_EXTENSION_STATE_DIR  = ${CMUX_EXTENSION_STATE_DIR:-<unset>}"
echo "HELLO_GREETING            = ${HELLO_GREETING:-<unset>}"
echo
echo "The cmux CLI is the extension API — try: cmux list-workspaces"
echo "Press Ctrl+C to exit to a shell in the extension root."
echo
while :; do
  printf '\r%s' "$(date '+%H:%M:%S')"
  sleep 1
done
