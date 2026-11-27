mobile host for macOS (Apple silicon): the Mac side the cmux mobile iPhone app connects to.

Quickstart
1. tar -xzf cmux-mobile-host-macos-arm64.tar.gz && cd cmux-mobile-host-macos-arm64
2. ./run-host.sh            (asks for your email and the 6-digit code; use the phone's account)
3. On the phone, open "cmux mobile" and sign in with the same account; this Mac appears under Workspaces.
4. ./bin/cmux-tui attach --socket ~/.cmux-mobile-host/sock/cmuxMobile.sock   (optional: open the session to add workspaces)
5. ./stop-host.sh           (stops everything; ./run-host.sh --sign-out forgets the sign-in)

Details
- Runs as you, in the background, with no sudo and no LaunchDaemons. State, logs and
  sockets live in ~/.cmux-mobile-host (override with CMUX_MOBILE_HOST_HOME). Tokens are kept in 0600 files.
- Sign-in alternatives: CMUX_MOBILE_STACK_EMAIL + CMUX_MOBILE_STACK_PASSWORD (password account, e.g. the
  dev test account the phone uses when you type 42 as the email), or CMUX_MOBILE_REFRESH_TOKEN_FILE.
- --prod signs in to the production Stack project, for the production app build
  ("cmux mobile", dev.cmux.mobile.prod). Its state lives in ~/.cmux-mobile-host-prod, so it runs beside a
  dev host; stop it with ./stop-host.sh --prod. Use your production (real) account.
- --team <id> joins a Stack team instead of your personal space (match the phone's team).
- --root <dir> lets phone sessions and file reads use that folder (default ~/.cmux-mobile-host/work).
- --seed creates a "cmux-mobile-demo" workspace in an empty session.
- The binaries are ad-hoc signed; run-host.sh removes the download quarantine flag.
- Service: the mobile dev service; nothing is installed system-wide.
