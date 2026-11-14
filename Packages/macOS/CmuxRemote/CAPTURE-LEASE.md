# Capture lease producer

`capture.prepare` and `capture.cleanup` are supervisor RPCs, reachable only
through the daemon's authenticated supervisor connection. They are not remote
CLI, phone, or worker-channel methods. The app facade owns the public
`debug.remote.capture_prepare` and `debug.remote.capture_cleanup` calls.

Both requests have exactly `lease_id` (24 lowercase hex characters), `bundle_id`
(the running tagged app's raw bundle identifier), and `private_root` (its private
HOME). The host checks its currently granted app process stamp and bundle ID,
and its own state directory must lie beneath that private, owner-only HOME.
This binds a namespace; it does not grant or replace whole-host fleet admission.

Prepare claims only an empty worker Keychain namespace and never deletes.
Successful prepare permanently closes child admission in that host, so no late
writer can race the app's external host-exit observation. The app drains this
credential-free host before relaunch; a fresh host can start writers from the
active marker. Prepare does not set the terminal `cleaning` phase. Rejected
bindings never freeze admission or signal children.
The host and worker serialize marker changes with a nonblocking file lock.
Before any identity write the worker records that it started. Cleanup persists
`cleaning` before closing spawn admission, signaling owned children, or waiting
for their reaping. A crash, timeout or cleanup error retains that restart fence.
A cleaning marker refuses every later identity load/renewal.

Every child launch (including permission probes) has its own generation token.
Reaping one token cannot remove a different child after PID reuse. A failed
`waitpid` never establishes exit. The drain has a 15-second deadline and cleanup
cannot delete while a tracked writer remains.

The host deletes only its exact `<remote-bundle>.<scope>.device-hub` namespace,
refuses unknown account names, and treats errors in either Keychain store as
unknown rather than absence. It returns removal counts, namespace verification,
and an internal `host_stamp`; it returns `remote_exit_unverified`, never proof
of its own exit. The facade must disable both remote features, observe the
original stamped host and descendants exit, and clean its separately owned app
relay namespaces before it can return aggregate success or release admission.

The issue class is cleanup reporting success before writers are fenced and
reaped. Detectors: `RemoteCaptureLeaseTests`, `RemoteChildLifetimeTests`, and
`DeviceCaptureNamespaceTests` exercise wrong leases, nonempty/unreadable stores,
writer timeouts, durable restart fencing, generation-safe reaping, and honest
exit/absence results without credentials or global Keychain writes.

The daemon exposes the same three binding fields through verified-main-app
`remote-host-call` methods `capture.prepare`, `capture.resume`, and
`capture.cleanup`. It grants the app internally; callers do not chain grant,
config, or drain commands. Prepare can start a quiet host while both saved
features are off. Capture never rewrites those saved settings. Its durable
supervisor record and lifecycle lock fence ordinary calls, config changes,
ensure, upgrade replacement, and automatic restart through prepare/cleanup.
Unreadable or malformed records keep admission closed after daemon restart.

Prepare drains its original host and requires a kernel process-exit event plus
ESRCH from a signal-zero query of its recorded owned process group before
returning full proof. Permission errors and lingering zombies fail closed; no
process table is scanned. The app bundle binding is checked against the
executable of the socket peer’s retained audit token. The
public facade additionally verifies its own namespaces. A fresh credential-free
app process resumes only the same Prepared binding; resume does not start a
host, accepts no credentials, and persists Active before reopening admission.
Its result is exactly `ok: true`, `code: remote_capture_resumed`, and
`lease_bound: true`. A later credentialed launch can use normal settings.
Cleanup leaves a terminal Cleaning fence even after success and cannot resume.

The capture RPC has a 60-second answer deadline. Timeout or any missing proof
fails closed, retains ownership, and never authorizes releasing fleet admission.
Daemon causal tests live in `remote_host/capture_tests.rs`; dispatcher tests in
`server/remote_host_capture_tests.rs` reject unproved, page, agent, and remote
callers. They detect the class where a valid native cleanup RPC is unreachable
when signed out or a separate lifecycle owner restarts writers during cleanup.

Prepare waits up to 15 seconds for the startup permission probe to reap before
claiming idle child admission. A stalled probe returns `remote_prepare_timeout`
without claiming the namespace; a later competing spawn still fails closed.
`RemoteCaptureLeaseTests` covers both probe completion and timeout/retry.
The daemon retains a recoverable Cleaning fence even when host startup failed
before a host record existed. `capture_failed_ensure_leaves_a_recoverable_durable_fence`
restarts and retries that sequence; Prepared and Active still require host proof.
