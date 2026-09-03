import Foundation
import Observation

/// Owns every in-flight machine create. A create is not tied to the sheet
/// that started it: the sheet hands over a ``MachineCreateRequest`` and
/// closes, and this object keeps the operation alive, tracks its outcome,
/// and tells the person how it ended. The Machines panel observes
/// ``operations`` to render pending rows; ``didChangeNotification`` fires on
/// every mutation so panels that are not on screen still refresh when a
/// machine lands.
///
/// The coordinator never talks to the backend itself: each `start` receives
/// the launcher that runs the CLI (`cmux vm new …` / `cmux vm base open …`)
/// so the sheet, the Machines panel ＋, Set Up Base, and tests share one path.
@MainActor
@Observable
final class MachineCreateCoordinator {
    /// Starts the CLI with the arguments; returns false when it could not
    /// launch (a sign-out raced the click). The completion carries the exit
    /// status and combined output, which is the error text on failure.
    typealias Launch = @MainActor (
        [String],
        @escaping @MainActor (String) -> Void,
        @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> Bool

    /// How a create ended.
    enum Outcome: Equatable {
        /// The machine exists and, when the CLI opened it, `workspaceID` is
        /// the local workspace it opened into.
        case created(machineID: String?, workspaceID: UUID?)
        /// `vm new` minted the machine but then failed to open it (terminal
        /// attach, desktop split). The machine is real: the row is dropped in
        /// favor of the fleet row and the person is pointed at the list.
        case createdButOpenFailed(machineID: String, output: String)
        /// Nothing was created; the row stays and offers Retry.
        case failed(output: String)
    }

    struct Finished: Equatable {
        let operation: MachineCreateOperation
        let outcome: Outcome
    }

    static let shared = MachineCreateCoordinator(notifier: MachineCreateNotifier().post)

    /// Posted on the default center with `object` = the coordinator after any
    /// change to ``operations``. `userInfo[finishedUserInfoKey]` carries the
    /// ``Finished`` value when the change is a completion.
    static let didChangeNotification = Notification.Name("cmux.machineCreate.didChange")
    static let finishedUserInfoKey = "finished"

    private(set) var operations: [MachineCreateOperation] = []
    /// The most recent completion, for observers that arrive late (tests,
    /// panels mounted after the fact).
    private(set) var lastFinished: Finished?

    /// Bookkeeping, not row state: kept out of observation so a launcher swap
    /// never invalidates views, and so `deinit` (nonisolated) can reach the
    /// observer token without going through an isolated accessor.
    @ObservationIgnored private var launches: [UUID: Launch] = [:]
    @ObservationIgnored private var progressOutput: [UUID: String] = [:]
    @ObservationIgnored private var attemptGeneration: [UUID: UInt64] = [:]
    @ObservationIgnored private let notifier: @MainActor (MachineCreateNotice) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var accessDidEndObserver: NSObjectProtocol?

    init(
        notifier: @escaping @MainActor (MachineCreateNotice) -> Void,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default
    ) {
        self.notifier = notifier
        self.now = now
        self.notificationCenter = notificationCenter
        // A sign-out cancels the launcher's child processes; their late
        // completions must not resurrect rows for an account that is gone.
        accessDidEndObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAllForAuthTransition() }
        }
    }

    deinit {
        if let accessDidEndObserver {
            notificationCenter.removeObserver(accessDidEndObserver)
        }
    }

    var hasRunningOperations: Bool { operations.contains(where: \.isRunning) }

    func operation(id: UUID) -> MachineCreateOperation? {
        operations.first { $0.id == id }
    }

    /// Launches the create and records it. Returns false, recording nothing,
    /// when the launcher refused (the caller shows that inline: the person is
    /// still looking at the sheet at that moment). The operation is registered
    /// BEFORE the launcher runs so a completion that fires synchronously still
    /// finds its row; a refused launch takes the registration back down.
    @discardableResult
    func start(_ request: MachineCreateRequest, launch: @escaping Launch) -> Bool {
        let operation = MachineCreateOperation(id: UUID(), request: request, startedAt: now())
        operations.append(operation)
        launches[operation.id] = launch
        progressOutput[operation.id] = ""
        attemptGeneration[operation.id] = 1
        postDidChange(finished: nil)
        guard launch(request.arguments, progressHandler(for: operation.id, generation: 1), completionHandler(for: operation.id, generation: 1)) else {
            if let index = operations.firstIndex(where: { $0.id == operation.id }) {
                operations.remove(at: index)
            }
            launches.removeValue(forKey: operation.id)
            progressOutput.removeValue(forKey: operation.id)
            attemptGeneration.removeValue(forKey: operation.id)
            postDidChange(finished: nil)
            return false
        }
        return true
    }

    /// Re-runs a failed create with its original arguments and launcher.
    /// Only failures that created nothing are retriable; a "created but
    /// opening failed" outcome never comes back here (a second run would mint
    /// a second machine).
    @discardableResult
    func retry(_ id: UUID) -> Bool {
        guard let index = operations.firstIndex(where: { $0.id == id }),
              !operations[index].isRunning,
              let launch = launches[id] else { return false }
        operations[index].phase = .running
        operations[index].createdMachineID = nil
        let generation = (attemptGeneration[id] ?? 0) &+ 1
        attemptGeneration[id] = generation
        progressOutput[id] = ""
        postDidChange(finished: nil)
        guard launch(operations[index].request.arguments, progressHandler(for: id, generation: generation), completionHandler(for: id, generation: generation)) else {
            if let failedIndex = operations.firstIndex(where: { $0.id == id }) {
                operations[failedIndex].phase = .failed(output: String(
                    localized: "machines.new.error.launch",
                    defaultValue: "cmux could not start the create command. Sign in and try again."
                ))
                progressOutput.removeValue(forKey: id)
                attemptGeneration[id] = (attemptGeneration[id] ?? generation) &+ 1
                postDidChange(finished: nil)
            }
            return false
        }
        return true
    }

    /// Drops a failed row. Running creates cannot be dismissed: the CLI is
    /// still working and its outcome must reach the person.
    func dismiss(_ id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }), !operations[index].isRunning else { return }
        operations.remove(at: index)
        launches.removeValue(forKey: id)
        progressOutput.removeValue(forKey: id)
        attemptGeneration.removeValue(forKey: id)
        postDidChange(finished: nil)
    }

    /// Forgets every operation. Completions for the dropped ids are ignored.
    func cancelAllForAuthTransition() {
        guard !operations.isEmpty || !launches.isEmpty else { return }
        operations.removeAll()
        launches.removeAll()
        progressOutput.removeAll()
        attemptGeneration.removeAll()
        postDidChange(finished: nil)
    }

    /// Recognizes only the CLI's strict stdout protocol line.
    nonisolated static func createdMachineID(fromOutput output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("OK machine=") else { continue }
            let payload = line.dropFirst("OK machine=".count)
            let id = payload.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
            let suffix = payload.dropFirst(id.count)
            guard suffix.isEmpty || suffix.first?.isWhitespace == true else { continue }
            return id
        }
        return nil
    }

    /// The failure text every surface shows (row tooltip, control bar, Show
    /// Error, Copy Error, notification): the CLI transcript with the app's
    /// standard redaction applied once, at storage time. Progress/token lines
    /// ("Created Cloud VM …", "OK machine=…") are dropped first so the reason
    /// leads. Redacted transcripts fall back to their first safe line plus the
    /// hidden-details placeholder, matching `CloudVMActionLauncher`'s alerts.
    nonisolated static func displayableFailureOutput(_ output: String) -> String {
        let generic = String(localized: "machines.new.error.generic", defaultValue: "The machine could not be created.")
        let stripped = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("OK ") && Self.createdMachineID(fromOutput: trimmed) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return generic }
        let safe = CloudVMActionLauncher.sanitizedCloudVMStartOutput(String(stripped.prefix(4000)))
        guard safe == CloudVMActionLauncher.hiddenOutputPlaceholder else {
            return safe.isEmpty ? generic : safe
        }
        guard let reason = CloudVMActionLauncher.firstSafeLine(of: stripped) else { return safe }
        return "\(reason)\n\(safe)"
    }

    private func completionHandler(for id: UUID, generation: UInt64) -> @MainActor (CloudVMActionLauncher.Completion) -> Void {
        { [weak self] completion in
            guard let self, self.attemptGeneration[id] == generation else { return }
            self.finish(id: id, completion: completion)
        }
    }

    private func progressHandler(for id: UUID, generation: UInt64) -> @MainActor (String) -> Void {
        { [weak self] chunk in
            guard let self,
                  self.attemptGeneration[id] == generation,
                  let index = self.operations.firstIndex(where: { $0.id == id }) else { return }
            var bounded = Data((self.progressOutput[id, default: ""] + chunk).utf8)
            bounded = Data(bounded.suffix(32 * 1024))
            while !bounded.isEmpty && String(data: bounded, encoding: .utf8) == nil { bounded.removeFirst() }
            self.progressOutput[id] = String(data: bounded, encoding: .utf8) ?? ""
            if let machineID = Self.createdMachineID(fromOutput: self.progressOutput[id] ?? "") {
                guard self.operations[index].createdMachineID != machineID else { return }
                self.operations[index].createdMachineID = machineID
                self.postDidChange(finished: nil)
            }
        }
    }

    private func finish(id: UUID, completion: CloudVMActionLauncher.Completion) {
        // Dropped by a sign-out (or dismissed after a retry was refused): the
        // account this belonged to is gone, so there is nobody to tell.
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        progressOutput.removeValue(forKey: id)
        attemptGeneration[id] = (attemptGeneration[id] ?? 0) &+ 1
        var operation = operations[index]
        let output = completion.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The launcher's machine id comes only from the strict stdout protocol.
        let createdMachineID = completion.machineId
        if let createdMachineID {
            operation.createdMachineID = createdMachineID
            operations[index].createdMachineID = createdMachineID
        }
        let outcome: Outcome
        if completion.succeeded {
            outcome = .created(machineID: createdMachineID, workspaceID: completion.workspaceId)
            operations.remove(at: index)
            launches.removeValue(forKey: id)
            attemptGeneration.removeValue(forKey: id)
        } else if !operation.request.isBaseSetup, let machineID = createdMachineID {
            // Base setup is idempotent (`vm base open` reopens the same slot),
            // so only `vm new` can leave a machine behind that must not be re-created.
            outcome = .createdButOpenFailed(machineID: machineID, output: Self.displayableFailureOutput(output))
            operations.remove(at: index)
            launches.removeValue(forKey: id)
            attemptGeneration.removeValue(forKey: id)
        } else {
            let failure = Self.displayableFailureOutput(output)
            outcome = .failed(output: failure)
            operations[index].phase = .failed(output: failure)
        }
        let finished = Finished(operation: operation, outcome: outcome)
        lastFinished = finished
        notifier(MachineCreateNotice(finished: finished))
        postDidChange(finished: finished)
    }

    private func postDidChange(finished: Finished?) {
        var userInfo: [AnyHashable: Any] = [:]
        if let finished {
            userInfo[Self.finishedUserInfoKey] = finished
        }
        notificationCenter.post(name: Self.didChangeNotification, object: self, userInfo: userInfo)
    }
}
