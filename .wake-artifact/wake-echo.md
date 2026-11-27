Machine vm_351c4972138251aa9aad, size {"platform":{"cpu":2,"memory_mb":4096,"disk_mb":20480},"guest":"nproc 2 MemTotal:        4008964 kB"}. 20 of 50 asked cycles: 13 echoed, 7 failed (counted apart). Seconds, runner clock; percentiles over the 13 that echoed.

| phase | n | p50 | p95 | max |
|---|---|---|---|---|
| restore | 13 | 4.96 | 137.65 | 137.65 |
| net_up | 13 | 0.11 | 6.47 | 6.47 |
| pty_attach | 13 | 0.06 | 6.70 | 6.70 |
| echo | 13 | 0.00 | 0.59 | 0.59 |
| **wake-to-first-echo** | 13 | 5.01 | 138.10 | 138.10 |

Biggest phase by p95: **restore**. state.json carried a wake block in 3 of 20 cycles.

### Wake on intent: key-to-echo by arm (client timer, paired cycles)

Target 1.00 s. Lead: the hint's start before the first key.

| lead | arm | n | p50 | p95 | under target |
|---|---|---|---|---|---|
| 0.50 | baseline | 13 | 5.01 | 138.10 | 0/13 |
| 0.50 | prefetch | 0 | - | - | 0/0 |
| 0.50 | wake-on-intent | 13 | 4.51 | 137.60 | 0/13 |
| 0.50 | both | 0 | - | - | 0/0 |
| 1.00 | baseline | 13 | 5.01 | 138.10 | 0/13 |
| 1.00 | prefetch | 0 | - | - | 0/0 |
| 1.00 | wake-on-intent | 13 | 4.01 | 137.10 | 0/13 |
| 1.00 | both | 0 | - | - | 0/0 |
| 2.00 | baseline | 13 | 5.01 | 138.10 | 0/13 |
| 2.00 | prefetch | 0 | - | - | 0/0 |
| 2.00 | wake-on-intent | 13 | 3.01 | 136.10 | 2/13 |
| 2.00 | both | 0 | - | - | 0/0 |
| 4.00 | baseline | 13 | 5.01 | 138.10 | 0/13 |
| 4.00 | prefetch | 0 | - | - | 0/0 |
| 4.00 | wake-on-intent | 13 | 1.01 | 134.10 | 6/13 |
| 4.00 | both | 0 | - | - | 0/0 |

A false wake (no input in 30 s) costs 39.04 s awake p50, 219.53 s p95 (n 13): wait to running + the bound + the pause.

Stopped early: 3 failed cycles in a row after 20 of 50.

Failures by cause:
- daemon restarted across the wake (product): 2
- guest unreachable: 3
- platform op: 1
- machine state: 1

Failed cycles:
- #6 (daemon restarted across the wake (product)): guest probe: attach: RuntimeError: attach refused: {"error": "unknown surface 6", "id": 3, "ok": false} — evidence {"surface":6,"setup_daemon":{"pid":25576,"start":37094389},"daemon_now":{"pid":27164,"start":37125279},"same_daemon":false,"workspaces":"{\"generation\": \"85691d63-f236-4732-b7fa-5b88a0b6d7de\", \"groups\": [], \"lines_written_before_read\": 3, \"pane_revision\": 2, \"registry_id\": \"e374a9c5-14c3-47c0-883e-5052df832327\", \"terminal_revision\": 10, \"workspace_revision\": 2, \"workspaces\": [{\"active\": false, \"app\": null, \"color\": null, \"group\": null, \"icon\": null, \"id\": 1, \"key\": \"2a3f5d85-01ff-41d9-9aed-91e51ac0187b\", \"kind\": \"normal\", \"marked_unread\": false, \"name\
- #8 (guest unreachable): no probe result 150 s after wake_at (exec first answered never ms); probe/gap logs: ==> /tmp/wake-echo/probe.log <== ==> /tmp/wake-echo/gaps.log <== {"prev_wall": 1795783530221.6614, "resumed_wall": 1795783541522.096, "wall_gap": 11300.4345703125, "mono_gap": 11300.359534978867, "armed": true} {"pre
- #11 (daemon restarted across the wake (product)): guest probe: attach: RuntimeError: attach refused: {"error": "unknown surface 13", "id": 3, "ok": false} — evidence {"surface":13,"setup_daemon":{"pid":27164,"start":37125279},"daemon_now":{"pid":30250,"start":37204248},"same_daemon":false,"workspaces":"{\"generation\": \"4f17603f-f894-447c-bc31-75a75a552eb3\", \"groups\": [], \"lines_written_before_read\": 3, \"pane_revision\": 3, \"registry_id\": \"e374a9c5-14c3-47c0-883e-5052df832327\", \"terminal_revision\": 18, \"workspace_revision\": 3, \"workspaces\": [{\"active\": false, \"app\": null, \"color\": null, \"group\": null, \"icon\": null, \"id\": 1, \"keep_awake\": false, \"key\": \"2a3f5d85-01ff-41d9-9aed-91e51ac0187b\", \"kind\": \"normal\", \"marked_
- #15 (guest unreachable): no probe result 150 s after wake_at (exec first answered never ms); probe/gap logs: unread
- #17 (platform op): cloud.machine.pause: HTTP 200 {"code":"mutation.indeterminate","message":"the provider call was cut off; retry with the same key","retryable":true}
- #18 (guest unreachable): no probe result 150 s after wake_at (exec first answered 5387 ms); probe/gap logs: unread
- #19 (machine state): pause did not land: the machine read pausing 180 s after the pause call

Warnings:
- #0: guest clock moved 7553 ms between pre-pause and post-wake offsets
- #2: guest clock moved 155 ms between pre-pause and post-wake offsets
- #3: guest clock moved 111 ms between pre-pause and post-wake offsets
- #4: guest clock moved 194 ms between pre-pause and post-wake offsets
- #6: guest clock moved -238 ms between pre-pause and post-wake offsets
- #7: guest clock moved 188 ms between pre-pause and post-wake offsets
- #9: guest clock moved 162 ms between pre-pause and post-wake offsets
- #10: guest clock moved 114 ms between pre-pause and post-wake offsets
- #12: guest clock moved 146 ms between pre-pause and post-wake offsets
- #14: guest clock moved -328 ms between pre-pause and post-wake offsets
