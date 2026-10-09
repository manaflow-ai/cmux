#!/usr/bin/env python3
"""Print pilot results.jsonl as a table (tolerates bc's '.24' seconds)."""
import json, re, sys
for line in open(sys.argv[1]):
    line = re.sub(r'"seconds":\.', '"seconds":0.', line.strip())
    if not line:
        continue
    d = json.loads(line)
    print("%-6s %-26s %8.2f exit=%s load=%s at=%s" % (d["tool"], d["scenario"], d["seconds"], d["exit"], d["load_before"], d["at"]))
