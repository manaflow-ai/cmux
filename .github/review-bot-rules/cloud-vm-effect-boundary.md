# Cloud VM Effect Boundary

Apply this rule to web changes under `web/app/api/vm/**` and `web/services/vms/**`. The Cloud VM control plane is an Effect boundary: business logic is an Effect program over `VmRepository`, `VmProviderGateway`, and `VmBillingGateway`; failures are tagged errors in the `VmWorkflowError` union; routes run programs through `runVmRoute` and answer failures from the shared responder table plus route-local overrides. The rule exists because the boundary was once only a middle layer, and each new endpoint written as plain `async` code re-created the predicate chains and untyped 500s the boundary removes.

## Fail

- A new or changed route under `web/app/api/vm/**` that awaits Drizzle, `cloudDb()`, `services/coderouter/teamMachines`, or a provider SDK directly instead of running a program in `web/services/vms/workflows.ts` (or a sibling workflow module) through `runVmRoute`.
- `Effect.runPromise`, `Effect.provide`, or `runVmWorkflow` inside a VM route handler, or a `try { … } catch (err) { if (isVm…Error(err)) … }` chain in a route where an `onError` overrides table is the contract.
- A new tagged error added to `web/services/vms/errors.ts` without adding it to `VmWorkflowError` and to `vmWorkflowErrorResponders` in `web/services/vms/routeHelpers.ts`, or a workflow failure modeled as a thrown `Error` or a `null` return instead of a tagged error.
- A new repository query written as a plain Promise function in `web/services/vms/**` and called from a workflow through `Effect.tryPromise` at the call site instead of a `VmRepository` method with a `VmDatabaseError` failure.
- A PR that adds a VM endpoint in plain code and defers the Effect migration to a follow-up.

## Pass

- A route that parses input, resolves auth and entitlements with the existing helpers, then calls `runVmRoute(program, { request, onError })` and branches on `run.ok`.
- Cron and account-deletion callers using `runVmWorkflow`, which has no HTTP error contract.
- Plain TypeScript in billing, coderouter, subrouter, vault, pages, and scripts: the rule covers the VM control plane only.
- Existing plain code the PR only touches incidentally, when it does not add a new endpoint or a new query path.

## Report

Name the file and line, say which part of the boundary is bypassed (route runs its own I/O, untyped failure, missing responder entry, per-route runtime), and point at the program, tagged error, and `runVmRoute` call that should replace it.
