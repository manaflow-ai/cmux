bash scripts/ci/init-submodule.sh ghostty-next
export GITHUB_PATH="$CI_TOOLS/zig-path" GITHUB_ENV="$CI_TOOLS/zig-env"
: > "$GITHUB_PATH"
: > "$GITHUB_ENV"
# Job-local, never sudo: a root-owned install in $CI_TOOLS failed the job at cleanup after every step passed.
# A machine that keeps RUNNER_TOOL_CACHE between jobs (a persistent runner, a build fleet pool VM whose image holds
# it) keeps the verified tarball there, so its next job checks the sha256 and unpacks, with no download.
export ZIG_TARBALL_CACHE_DIR="${ZIG_TARBALL_CACHE_DIR:-${RUNNER_TOOL_CACHE:+$RUNNER_TOOL_CACHE/zig}}"
GHOSTTY_ZIG_SOURCE=ghostty-next ZIG_FORCE_LOCAL_INSTALL=1 RUNNER_TEMP="$CI_TOOLS" ./scripts/install-zig-ci.sh
mkdir -p "$CI_TOOLS/bin"
zig_bin="$(sed -n 's/^CMUX_ZIG=//p' "$CI_TOOLS/zig-env" | tail -n 1)"
[ -x "$zig_bin" ] || { echo "no zig was installed"; exit 1; }
ln -sf "$zig_bin" "$CI_TOOLS/bin/zig"
