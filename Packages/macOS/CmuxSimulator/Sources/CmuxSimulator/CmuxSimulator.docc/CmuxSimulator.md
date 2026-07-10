# ``CmuxSimulator``

Use typed Simulator models, public `simctl` controls, and the supervised worker client that powers cmux Simulator panes.

## Target ownership

`CmuxSimulator` owns process-safe values, public command construction, and host-side worker supervision. `CmuxSimulatorWorker` owns private, version-gated Simulator framework access and can terminate without taking down cmux. `CmuxSimulatorUI` owns AppKit and SwiftUI presentation. The worker copies frames into global IOSurfaces that cmux resolves and retains, so Core Animation never composites a worker-owned rendering context. No CoreSimulator or SimulatorKit object enters cmux.

Private Simulator APIs must stay in the worker target. New control values belong in `Models`, public command operations in `Control`, wire messages in `WorkerProtocol`, and crash containment in `WorkerClient`.

Raw Web Inspector output crosses the process boundary as ordered ``SimulatorWebInspectorMessageChunk`` values. Consumers can stream chunks without assembling a heap snapshot or another large domain response into one host-worker frame.
