import Foundation

extension MachineCreateCoordinator {
    /// Drops a completed projection only after the fleet or catalog has
    /// acknowledged the exact provider id. Until then the same operation row
    /// remains visible and owns selection/focus identity.
    func reconcileAuthoritativeState(machineIDs: Set<String>, catalogMachineIDs: Set<String>) {
        let acknowledged = machineIDs.union(catalogMachineIDs)
        let removable = operations.filter { operation in
            guard let machineID = operation.reconcilingMachineID else { return false }
            return acknowledged.contains(machineID)
        }
        guard !removable.isEmpty else { return }
        let removableIDs = Set(removable.map(\.id))
        operations.removeAll { removableIDs.contains($0.id) }
        for id in removableIDs {
            cancellableLaunches.removeValue(forKey: id)
            cancellationHandles.removeValue(forKey: id)
            attemptGeneration.removeValue(forKey: id)
            progressOutput.removeValue(forKey: id)
            progressMarkerCarry.removeValue(forKey: id)
        }
        postDidChange(finished: nil)
    }

    /// Ends every operation whose optimistic workspace was explicitly closed.
    /// Running creates keep their tombstone so a late provider id is cleaned;
    /// a committed VM is simply detached from the local projection.
    func cancelOperations(forPresentationWorkspace workspaceID: UUID) {
        let ids = operations.compactMap { operation in
            operation.request.presentationWorkspaceID == workspaceID ? operation.id : nil
        }
        for id in ids {
            guard let operation = operation(id: id) else { continue }
            if operation.isRunning {
                cancel(id)
            } else if operation.failureOutput != nil {
                dismiss(id)
            } else if operation.isReconciling {
                operations.removeAll { $0.id == id }
                cancellableLaunches.removeValue(forKey: id)
                cancellationHandles.removeValue(forKey: id)
                attemptGeneration.removeValue(forKey: id)
                progressOutput.removeValue(forKey: id)
                progressMarkerCarry.removeValue(forKey: id)
                postDidChange(finished: nil)
            }
        }
    }


    func completionHandler(
        for id: UUID,
        generation: UInt64
    ) -> @MainActor (CloudVMActionLauncher.Completion) -> Void {
        { [weak self] completion in
            guard let self,
                  self.attemptGeneration[id] == generation
                    || self.cancelledCreates[id]?.generation == generation else { return }
            self.finish(id: id, completion: completion)
        }
    }

    func progressHandler(
        for id: UUID,
        generation: UInt64
    ) -> @MainActor (String) -> Void {
        { [weak self] chunk in
            guard let self else { return }
            if let index = self.operations.firstIndex(where: { $0.id == id }) {
                guard self.attemptGeneration[id] == generation else { return }
                // Parse the complete callback before bounding the retained
                // transcript. ProcessOutputCollector does not promise a small
                // chunk, so a marker at the beginning of a large callback must
                // still correlate the operation.
                let markerInput = self.progressMarkerCarry[id, default: ""] + chunk
                let machineID = Self.createdMachineID(fromOutput: markerInput)
                self.progressMarkerCarry[id] = String(markerInput.suffix(Self.markerCarryLimit))
                let bounded = (self.progressOutput[id, default: ""] + chunk).suffix(Self.outputParseLimit)
                self.progressOutput[id] = String(bounded)
                if let machineID {
                    guard self.operations[index].createdMachineID != machineID else { return }
                    self.operations[index].createdMachineID = machineID
                    self.postDidChange(finished: nil)
                }
                return
            }
            // The row is intentionally gone after Cancel, but the process can
            // still flush bytes. Keep parsing that tail for a provider id.
            guard var cancelled = self.cancelledCreates[id] else { return }
            guard cancelled.generation == generation else { return }
            let markerInput = cancelled.markerCarry + chunk
            let machineID = Self.createdMachineID(fromOutput: markerInput)
            cancelled.markerCarry = String(markerInput.suffix(Self.markerCarryLimit))
            if !cancelled.isBaseSetup,
               let machineID,
               cancelled.cleanedMachineID != machineID {
                cancelled.cleanedMachineID = machineID
                self.cleanupCancelledMachine(machineID)
            }
            self.cancelledCreates[id] = cancelled
        }
    }

    private func finish(id: UUID, completion: CloudVMActionLauncher.Completion) {
        // Dropped by a sign-out (or dismissed after a retry was refused): the
        // account this belonged to is gone, so there is nobody to tell.
        guard let index = operations.firstIndex(where: { $0.id == id }) else {
            guard var cancelled = cancelledCreates.removeValue(forKey: id) else { return }
            guard !cancelled.isBaseSetup else { return }
            let machineID = completion.machineId ?? Self.createdMachineID(fromOutput: completion.output)
            if let machineID, cancelled.cleanedMachineID != machineID {
                cancelled.cleanedMachineID = machineID
                cleanupCancelledMachine(machineID)
            }
            return
        }
        var operation = operations[index]
        let output = completion.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The CLI's `machine=` token is the authoritative created-machine
        // signal; the localized "Created Cloud VM" line is the fallback for
        // older bundled CLIs.
        let createdMachineID = completion.machineId
            ?? operation.createdMachineID
            ?? Self.createdMachineID(fromOutput: output)
        if let createdMachineID {
            operation.createdMachineID = createdMachineID
            operations[index].createdMachineID = createdMachineID
        }
        if completion.wasCancelled {
            operations.remove(at: index)
            cancellableLaunches.removeValue(forKey: id)
            cancellationHandles.removeValue(forKey: id)
            progressOutput.removeValue(forKey: id)
            attemptGeneration.removeValue(forKey: id)
            progressMarkerCarry.removeValue(forKey: id)
            if !operation.request.isBaseSetup, let createdMachineID {
                cleanupCancelledMachine(createdMachineID)
            }
            postDidChange(finished: nil)
            return
        }
        let outcome: Outcome
        if completion.succeeded {
            outcome = .created(machineID: createdMachineID, workspaceID: completion.workspaceId)
            cancellableLaunches.removeValue(forKey: id)
            cancellationHandles.removeValue(forKey: id)
            attemptGeneration.removeValue(forKey: id)
            progressOutput.removeValue(forKey: id)
            progressMarkerCarry.removeValue(forKey: id)
            if !operation.request.isBaseSetup,
               operation.request.reservedWorkspaceID != nil,
               let createdMachineID {
                operation.phase = .reconciling(machineID: createdMachineID)
                operations[index].phase = operation.phase
            } else {
                operations.remove(at: index)
            }
        } else if !operation.request.isBaseSetup, let machineID = createdMachineID {
            // Base setup is idempotent (`vm base open` reopens the same slot),
            // so only `vm new` can leave a machine behind that must not be re-created.
            outcome = .createdButOpenFailed(machineID: machineID, output: Self.displayableFailureOutput(output))
            operations.remove(at: index)
            cancellableLaunches.removeValue(forKey: id)
            cancellationHandles.removeValue(forKey: id)
            attemptGeneration.removeValue(forKey: id)
            progressOutput.removeValue(forKey: id)
            progressMarkerCarry.removeValue(forKey: id)
        } else {
            let failure = Self.displayableFailureOutput(output)
            outcome = .failed(output: failure)
            operations[index].phase = .failed(output: failure)
            progressOutput.removeValue(forKey: id)
            progressMarkerCarry.removeValue(forKey: id)
        }
        let finished = Finished(operation: operation, outcome: outcome)
        if case let .created(_, workspaceID) = outcome,
           let workspaceID,
           operation.request.selectsCreatedWorkspace {
            selectCreatedWorkspace(workspaceID, for: operation.request)
        }
        lastFinished = finished
        notifier(MachineCreateNotice(finished: finished))
        postDidChange(finished: finished)
    }
    /// De-duplicates cleanup requests when a machine id appears in progress
    /// output and again in the process's final completion.
    func cleanupCancelledMachine(_ machineID: String) {
        let normalized = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, cleanupIssuedMachineIDs.insert(normalized).inserted else { return }
        cancelCreatedMachine(normalized)
    }

    /// Retains a bounded cancellation tombstone. The process completion normally
    /// removes it; if a child disappears without a callback, the oldest entry is
    /// evicted rather than allowing repeated failed launches to grow without
    /// bound.
    func retainCancelledCreate(_ cancelled: CancelledCreate, for id: UUID) {
        if cancelledCreates.count >= Self.maximumCancelledCreates,
           let oldest = cancelledCreates.keys.first {
            cancelledCreates.removeValue(forKey: oldest)
        }
        cancelledCreates[id] = cancelled
    }

    func postDidChange(finished: Finished?) {
        var userInfo: [AnyHashable: Any] = [:]
        if let finished {
            userInfo[Self.finishedUserInfoKey] = finished
        }
        notificationCenter.post(name: Self.didChangeNotification, object: self, userInfo: userInfo)
    }
}
