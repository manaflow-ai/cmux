cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; python3 .scratch-gg15/probe.py 2>&1 | cut -c1-300
