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
