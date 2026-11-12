import sys, re
from pathlib import Path
sys.path.insert(0, "scripts/ci"); sys.path.insert(0, "tests")
import github_token_polling as g
from shell_invocations import may_run_nested
for path in ["scripts/ci/package-test-lane.sh", "scripts/ci/tip-test-compile.sh", "scripts/cmux-next/wait-dev-daily-tree.sh",
             "scripts/cmux-next/pin-cmux-tui.sh", "scripts/cmux-next/await-tree-client.sh"]:
    text = Path(path).read_text()
    loops, functions = g.shell_blocks(g.shell_words(text), text)
    url = g.api_url_pattern(g.api_url_names(text))
    for words, body in loops:
        if not g.shell_api(body, url) and not g.shell_calls(body, functions):
            continue
        seen, todo, why_api, why_sleep = set(), [(words, body)], [], []
        while todo:
            w, b = todo.pop()
            for cmd in may_run_nested(b):
                if not cmd: why_api.append("UNREADABLE")
                elif g._program(cmd[0]) == "gh": why_api.append(" ".join(cmd[:4]))
                elif g._program(cmd[0]) == "curl" and any(url.search(x) for x in cmd[1:]): why_api.append("curl")
                if cmd and g._program(cmd[0]) == "sleep": why_sleep.append("sleep")
            for n in g.shell_calls(b, functions) - seen:
                seen.add(n); todo.append(functions[n])
        if why_api and why_sleep:
            print(path, "|", " ".join(words[:6]), "| api:", sorted(set(why_api))[:6], "| fns:", sorted(seen)[:8])
