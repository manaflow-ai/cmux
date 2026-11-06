# Agent chat stress rig

Live checks of the phone's agent chat against a real cmux-next Mac, under long
and short runs: big transcripts, floods, many turns, reconnects, backgrounding,
rapid taps, interrupts and approvals.

The rig runs on one cmux mini. It has two parts:

- The hidden e2e rig Mac app (`verify/e2e/mac.py`). It has its own bundle id,
  config and credentials, and launches with `open -g -j`, never activated. Its
  acpmux runs in `~/agentqa/rig/acpmux`, with `agentqa_agent.py` as its default
  harness. That harness is acpmux's credit-free `tests/fake_agent.py` plus
  stress prompts. No model is called.
- The iOS app (Demo configuration) in one headless simulator, driven by AXe.
  Simulator.app is never opened.

The phone starts its chats itself (`+` > New Agent Chat), as a person does. The
rig reads back what the Mac's acpmux recorded to check order and sync.

## Stress prompts

| Prompt | What the agent does |
| --- | --- |
| `md: N` | Streams a markdown answer of N sections (headings, lists, tables, code, links), 40 characters per chunk, 30 ms apart |
| `flood: N` | Sends N chunks with no delay |
| `seq: N` | Sends N numbered chunks (`1\|2\|…`), 20 ms apart, so a check can read the answer back and find loss or reordering |
| `tools: N` | Makes N tool calls (read, search, execute), each running and then completed with output |
| `think: N` | Streams N thought lines, 0.5 s apart |
| `long: S` | Sends one chunk per second for S seconds, so the turn outlives backgrounding and link drops |
| `ask: X`, `question: X`, `slow`, `until-cancel`, … | Behave as in `fake_agent.py` |

## Use

```sh
# On the mini, in ~/agentqa (aq.py, agentqa_agent.py and fake_agent.py copied there;
# src/ is a checkout whose cmux-next-ios/verify/e2e the rig imports):
python3 -c 'from aq import *; up("mac/cmux DEV TAG.app", "out/base/CmuxMobileApp.app")'
python3 -c 'from aq import *; rec_start("seq"); perf_start("seq")'
python3 -c 'from aq import *; print(perf_stop()); rec_stop(); shot("after")'
python3 -c 'from aq import *; down()'
```

`perf_start` samples the app's CPU and resident memory. On the mini the
simulator app is an ordinary host process. `sample(5)` takes its stacks.

Evidence goes to `~/agentqa/ev/<run>/`: `shots/`, the `.mp4` recordings and
`perf/*.jsonl` with a summary beside each.
