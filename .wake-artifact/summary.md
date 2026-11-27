FAIL: Cloud journey on `staging` (https://cloud-api-staging.cmux.dev), 256.5 s

tag: jr-mwyywwss, team: (personal), agent: claude, exec: client session, model: stub (on the machine)

agent_ready_ms: - (cold); first_reply_ms: -
- M17 click to agent ready, warm: not judged: a cold start
- G1 first reply, warm: not judged: a cold start
- M3 agent started step: not judged: not measured

| result | step | ms | detail |
|---|---|---:|---|
| pass | health | 62 | commit 0.1.0 |
| pass | sign in (agent test account) | 436 | Stack project 454ecd03 |
| pass | user.ensure | 987 | user user_4b0ad73155f1c6cad934 |
| pass | install token | 404 | install inst_82b74511f270b07e90e8 |
| pass | team-scoped install token | 221 | team team_968c8afd7c1f2b21e6b8 via user.teams.list (which heals the team before the mint), minted in 118 ms |
| pass | capacity preflight (quota headroom) | 1557 | quota_headroom:account-team used 103/9007199254740991, need 2: room |
| pass | create machine | 26251 | vm_351c4972138251aa9aad status provisioning |
| pass | running (status) | 102407 | host host_55034302dc5854686928, daemon 1.0.0+58845c13653b; retried once after owner.unreachable |
| pass | wake-echo machine size | 54453 | {"platform":{"cpu":2,"memory_mb":4096,"disk_mb":20480},"guest":"nproc 2 MemTotal:        4008964 kB"} |
| pass | wake-echo idle policy off | 1586 | idle_seconds 0 |
| pass | wake-echo probe setup | 11019 | daemon socket, terminal and dry run ok |
| **FAIL** | wake-echo | 0 | 13 of 50 asked echoed (20 ran); stopped: 3 failed cycles in a row after 20 of 50; failures {"daemon restarted across the wake (product)":2,"guest unreachable":3,"platform op":1,"machine state":1} |
| skip | guest updater (before-cleanup) | 4935 | collected; updater=current; first_ready=on_image; full evidence: guest-updater.json |
| skip | failure facts | 15027 | read before any delete: {"machine":{"status":"running","daemon_version":"1.0.0+8df97dc42eb0"},"timeline":null,"timeline_error":"guest carrier timeline: no answer in 15000 ms"} |
| pass | revoke install (cleanup) | 286 | inst_82b74511f270b07e90e8 |
| **FAIL** | delete (cleanup) | 36895 | cloud.machine.delete: HTTP 503 {"_tag":"OwnerUnreachable","code":"owner.unreachable","message":"Error: Durable Object exceeded its CPU time limit and was reset.","retryable":true} |
