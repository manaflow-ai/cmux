import Foundation

/// The person's input on a Cloud machine, by the steps of `cmux cloud computer` (cloud_tools.rs
/// DESKTOP_PRELUDE and desktop_step), run through the machine's exec while they hold control. The
/// capture scope stays on desktop afterwards: this runs beside the screen reads, and putting it back
/// could change it under one of them.
extension HomeChiefComputerRoute {
    private static let machineDesktopPrelude = ##"""
export HOME=/home/cmux PATH=/opt/cmux/current/bin:$PATH DISPLAY=:99 XAUTHORITY=/home/cmux/.cache/cmux-display/Xauthority-99 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/cmux-agent-a11y-99/bus; command -v cmux-cua >/dev/null 2>&1 || { echo 'this machine has no cmux-cua: it is too old for computer use' >&2; exit 127; }; cmux-cua status >/dev/null 2>&1 || sudo -n systemctl start cmux-agent-cua.service >/dev/null 2>&1 || { echo 'the computer-use driver did not start (systemctl status cmux-agent-cua.service)' >&2; exit 1; }; cua() { e=$(mktemp); out=$(cmux-cua call "$1" "$2" 2>"$e"); rc=$?; err=$(cat "$e"); rm -f "$e"; first=$(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}'); case "$first" in '{'*|'✅'*|'Agent cursor '*) ok=1 ;; *) ok= ;; esac; if [ "$rc" -ne 0 ] || [ -z "$ok" ] || printf '%s\n' "$out" | grep -Eq '^  "(code|error)"[[:space:]]*:|^[{][[:space:]]*"(code|error)"[[:space:]]*:'; then printf 'cmux-cua %s: %s %s\n' "$1" "$out" "$err" | tail -c 800 >&2; return 1; fi; printf '%s\n' "$out"; }; cua_scope=$(cmux-cua call get_config '{}' 2>/dev/null | sed -n 's/^[[:space:]]*"capture_scope":[[:space:]]*"\([a-z]*\)".*/\1/p'); if [ "$cua_scope" != desktop ]; then cua set_config '{"capture_scope":"desktop"}' >/dev/null || exit 1; fi; CUA_PICK='import json,os,sys
ws=[w for w in json.loads(os.environ["CUA_WINDOWS"]).get("windows",[]) if w.get("pid") and w.get("is_on_screen",True)]
ws.sort(key=lambda w:-w.get("z_index",0))
at=os.environ["CUA_AT"].split()
if at:
    px,py=float(at[0]),float(at[1])
    ws=[w for w in ws if w["x"]<=px<w["x"]+w["width"] and w["y"]<=py<w["y"]+w["height"]]
if not ws: sys.exit("no app window there on the desktop: open one with open_url, or take a screenshot")
w=ws[0]; a=json.loads(os.environ["CUA_ARGS"])
for k,o,n in (("x","x","width"),("from_x","x","width"),("to_x","x","width"),("y","y","height"),("from_y","y","height"),("to_y","y","height")):
    if k in a: a[k]=int(min(max(a[k]-w[o],0),w[n]-1))
a.update(pid=w["pid"],window_id=w["window_id"],delivery_mode="foreground")
print(json.dumps(a))'; cua_win() { j=$(cua list_windows '{"on_screen_only":true}') || return 1; a=$(CUA_WINDOWS="$j" CUA_AT="$1" CUA_ARGS="$3" python3 -c "$CUA_PICK") || return 1; cua "$2" "$a"; }; pointer_to() { out=$(agent-desktop --headed mouse-move --xy "$1,$2" 2>&1); printf '%s' "$out" | grep -q '"ok":true' || { printf 'agent-desktop mouse-move: %s\n' "$out" | tail -c 600 >&2; return 1; }; cua move_cursor "{\"x\":$1,\"y\":$2}"; }; app_windows() { cmux-cua call list_windows '{"on_screen_only":true}' 2>/dev/null | python3 -c 'import json,sys;print(sum(1 for w in json.load(sys.stdin).get("windows",[]) if w.get("pid")))' 2>/dev/null || echo 0; }; chief_chrome() { c=$(python3 -c 'import json;print(json.load(open("/etc/cmux/roles.json"))["roles"]["browser"]["env"]["CMUX_BROWSER_HOST_CHROMIUM"])' 2>/dev/null); [ -x "$c" ] || c=$(command -v google-chrome-stable || command -v google-chrome || command -v chromium); [ -n "$c" ] || { echo 'this machine has no Chrome' >&2; return 1; }; n0=$(app_windows); setsid -f "$c" --user-data-dir=/home/cmux/.cache/cmux-computer/chrome --no-first-run --no-default-browser-check --force-renderer-accessibility --window-position=0,0 --window-size=1280,800 --new-window "$1" >/dev/null 2>&1 </dev/null; end=$(($(date +%s) + 8)); while [ "$(date +%s)" -lt "$end" ]; do [ "$(app_windows)" -gt "$n0" ] && { echo '{"opened":true}'; return 0; }; sleep 0.25; done; echo 'Chrome showed no new window in 8 s' >&2; return 1; }; 
"""##

    /// The shell for `input`; nil for an input with nothing to do on the machine (a bare pointer move).
    public static func machineInputCommand(_ input: HomeChiefComputerInput) -> String? {
        let step: String
        switch input {
        case let .click(x, y, button, count):
            let name = button == 3 ? "right" : button == 2 ? "middle" : "left"
            let one = "cua click \(quoted(json(["x": x, "y": y, "button": name])))"
            step = Array(repeating: one, count: min(max(count, 1), 3)).joined(separator: " && ")
        case .move:
            return nil
        case let .drag(fromX, fromY, toX, toY):
            step = onWindow("\(fromX) \(fromY)", "drag", ["from_x": fromX, "from_y": fromY, "to_x": toX, "to_y": toY])
        case let .scroll(x, y, direction, amount):
            step = onWindow("\(x) \(y)", "scroll", ["x": x, "y": y, "direction": direction, "amount": max(amount, 1), "by": "line"])
        case let .type(text):
            step = onWindow("", "type_text", ["text": text])
        case let .key(keys):
            let parts = keys.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            step = parts.count == 1 ? onWindow("", "press_key", ["key": parts[0]]) : onWindow("", "hotkey", ["keys": parts])
        }
        return machineDesktopPrelude + step
    }

    private static func onWindow(_ at: String, _ tool: String, _ arguments: [String: Any]) -> String {
        "cua_win \(quoted(at)) \(tool) \(quoted(json(arguments)))"
    }

    private static func json(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
