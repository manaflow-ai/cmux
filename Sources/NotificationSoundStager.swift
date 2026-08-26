import AVFoundation
import CmuxFoundation
import CmuxSettings
import Foundation
import os

nonisolated private let notificationSoundStagerLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification-sound"
)

/// Gives a cancellation handler a Sendable way to terminate an `afconvert`
/// process without capturing the Foundation process directly in a concurrent
/// closure.
/// Sole owner of notification-sound staging artifacts.
///
/// Actor isolation serializes every managed-file write, including metadata
/// sidecars and `.m4r` transcoding. Conversion suspends while `afconvert`
/// reports termination, so the actor remains available to other callers while
/// each transaction still commits its artifact serially.
actor NotificationSoundStager {
    typealias PreparationIssue = NotificationSoundSettings.CustomSoundPreparationIssue
    private typealias InFlightConversion = (
        id: UUID,
        task: Task<NotificationSoundProcessRunner.Result, Error>,
        sourceURL: URL,
        sourceMetadata: NotificationSoundSourceMetadata?,
        waiterIDs: Set<UUID>,
        cancellationRequested: Bool
    )

    private let processRunner = NotificationSoundProcessRunner()
    private let artifactCleaner = NotificationSoundStagingArtifactCleaner()
    private var inFlightConversions: [URL: InFlightConversion] = [:]
    private var artifactLeaseExpirations: [URL: Date] = [:]
    private var pendingArtifactReferences: [String: Set<URL>] = [:]
    private var pendingArtifactReferenceExpirations: [String: Date] = [:]
    private let artifactLeaseDuration: TimeInterval = 10 * 60
    private let pendingArtifactReferenceGracePeriod: TimeInterval = 24 * 60 * 60
    private let maximumPendingArtifactReferences = 512
    private let maximumArtifactLeases = 512
    private var lastArtifactPruneAt = Date.distantPast
    private let artifactPruneInterval: TimeInterval = 60

    func stagedName(
        path rawPath: String,
        stagingDirectory: URL?
    ) async -> String? {
        guard let normalized = NotificationSoundSettings.normalizedPath(rawPath) else {
            log(.emptyPath)
            return nil
        }
        guard let sourceURL = NotificationSoundSettings.expandedURL(for: normalized) else {
            log(.emptyPath)
            return nil
        }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else {
            log(.missingFileExtension(path: sourceURL.path))
            return nil
        }

        let destinationExtension = NotificationSoundSettings.stagedFileExtension(
            forSourceExtension: sourceExtension
        )
        let stagedFileName = NotificationSoundSettings.stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = NotificationSoundSettings.stagedURL(
            named: stagedFileName,
            stagingDirectory: stagingDirectory
        )
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            log(.missingFile(path: sourceURL.path))
            return nil
        }

        if isCurrentArtifact(
            sourceURL: sourceURL,
            stagedURL: stagedURL,
            fileManager: fileManager
        ) {
            return stagedFileName
        }

        switch await prepareCustomSound(path: normalized, stagingDirectory: stagingDirectory) {
        case .success(let preparedName):
            return preparedName
        case .failure(let issue):
            log(issue)
            return nil
        }
    }

    /// Returns an existing current artifact without copying or transcoding.
    func stagedNameIfReady(
        path rawPath: String,
        stagingDirectory: URL?
    ) -> String? {
        guard let normalized = NotificationSoundSettings.normalizedPath(rawPath),
              let sourceURL = NotificationSoundSettings.expandedURL(for: normalized) else {
            return nil
        }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else { return nil }

        let destinationExtension = NotificationSoundSettings.stagedFileExtension(
            forSourceExtension: sourceExtension
        )
        let stagedFileName = NotificationSoundSettings.stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = NotificationSoundSettings.stagedURL(
            named: stagedFileName,
            stagingDirectory: stagingDirectory
        )
        return isCurrentArtifact(
            sourceURL: sourceURL,
            stagedURL: stagedURL,
            fileManager: .default
        ) ? stagedFileName : nil
    }

    func prepareCustomSound(
        path rawPath: String,
        stagingDirectory: URL?
    ) async -> Result<String, PreparationIssue> {
        guard let normalized = NotificationSoundSettings.normalizedPath(rawPath),
              let sourceURL = NotificationSoundSettings.expandedURL(for: normalized) else {
            return .failure(.emptyPath)
        }
        return await prepareCustomSound(
            from: sourceURL,
            destinationDirectory: NotificationSoundSettings.soundDirectoryURL(stagingDirectory)
        )
    }

    func validateCustomSoundFileForSelection(
        path: String,
        stagingDirectory: URL?,
        decoder: (@Sendable (URL) -> Bool)?
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let result = await prepareCustomSound(
            path: path,
            stagingDirectory: stagingDirectory
        )
        guard !Task.isCancelled else { return false }
        guard case .success(let stagedName) = result else { return false }
        let stagedURL = NotificationSoundSettings.stagedURL(
            named: stagedName,
            stagingDirectory: stagingDirectory
        )
        let fileManager = FileManager.default
        let isDecodable = decoder?(stagedURL) ?? isDecodableSoundFile(at: stagedURL)
        return !stagedName.isEmpty
            && fileManager.fileExists(atPath: stagedURL.path)
            && isDecodable
    }

    func prepareNotificationSound(
        snapshot: NotificationSoundResolutionSnapshot,
        stagingDirectory: URL?,
        pendingReferenceID: String?
    ) async -> PreparedNotificationSound {
        guard !Task.isCancelled else { return .silent }
        // `default` is a sparse-cell sentinel meaning “use the global
        // notifications.sound selection”, not the macOS system default.
        if let overrideSelection = snapshot.overrideSelection,
           overrideSelection.value != NotificationSoundOverride.defaultValue,
           let preparedOverride = await prepareSelection(
               overrideSelection,
               stagingDirectory: stagingDirectory
           ) {
            guard !Task.isCancelled else { return .silent }
            retainArtifact(
                for: preparedOverride,
                stagingDirectory: stagingDirectory,
                pendingReferenceID: pendingReferenceID
            )
            return preparedOverride
        }
        guard !Task.isCancelled else { return .silent }
        if let preparedGlobal = await prepareSelection(
            snapshot.globalSelection,
            stagingDirectory: stagingDirectory
        ) {
            guard !Task.isCancelled else { return .silent }
            retainArtifact(
                for: preparedGlobal,
                stagingDirectory: stagingDirectory,
                pendingReferenceID: pendingReferenceID
            )
            return preparedGlobal
        }
        if snapshot.globalSelection.value == NotificationSoundOverride.customFileValue {
            // Preserve global custom-file behavior: a missing global file is
            // silent. Only a missing matrix override falls back globally.
            return .silent
        }
        return .systemDefault
    }

    func stageSystemSound(
        value: String,
        allowedValues: Set<String>,
        sourceDirectory: URL,
        stagingDirectory: URL?
    ) -> String? {
        guard allowedValues.contains(value),
              value != NotificationSoundOverride.defaultValue,
              value != NotificationSoundOverride.customFileValue,
              value != NotificationSoundOverride.noneValue else {
            return nil
        }

        let fileManager = FileManager.default
        let sourceURL = sourceDirectory.appendingPathComponent(
            "\(value).aiff",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let destinationDirectory = NotificationSoundSettings.soundDirectoryURL(stagingDirectory)
        let destinationFileName = NotificationSoundSettings.systemSoundFileName(for: value)
        let destinationURL = destinationDirectory.appendingPathComponent(
            destinationFileName,
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            try copyIfNeeded(
                from: sourceURL,
                to: destinationURL,
                fileManager: fileManager
            )
            return destinationFileName
        } catch {
            notificationSoundStagerLogger.error(
                "Failed to stage notification system sound \(value, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private func prepareSelection(
        _ selection: ResolvedNotificationSoundPlaybackSelection,
        stagingDirectory: URL?
    ) async -> PreparedNotificationSound? {
        switch selection.value {
        case NotificationSoundOverride.defaultValue:
            return .systemDefault
        case NotificationSoundOverride.noneValue:
            return .silent
        case NotificationSoundOverride.customFileValue:
            guard let path = selection.customFilePath,
                  let sourceURL = NotificationSoundSettings.expandedURL(for: path),
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  case .success(let stagedName) = await prepareCustomSound(
                      path: path,
                      stagingDirectory: stagingDirectory
                  ) else {
                return nil
            }
            let stagedURL = NotificationSoundSettings.stagedURL(
                named: stagedName,
                stagingDirectory: stagingDirectory
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path),
                  isDecodableSoundFile(at: stagedURL) else {
                return nil
            }
            return .named(stagedName)
        default:
            guard NotificationSoundOverride.isValidSoundValue(selection.value),
                  let stagedName = stageSystemSound(
                      value: selection.value,
                      allowedValues: Set(NotificationSoundSettings.systemSounds.map { $0.value }),
                      sourceDirectory: NotificationSoundSettings.systemSoundDirectoryURL,
                      stagingDirectory: stagingDirectory
                  ) else {
                return nil
            }
            return .named(stagedName)
        }
    }

    private func prepareCustomSound(
        from sourceURL: URL,
        destinationDirectory: URL
    ) async -> Result<String, PreparationIssue> {
        guard !Task.isCancelled else { return .failure(.emptyPath) }
        let sourcePath = sourceURL.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else {
            return .failure(.missingFile(path: sourcePath))
        }
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceExtension.isEmpty else {
            return .failure(.missingFileExtension(path: sourcePath))
        }

        let destinationExtension = NotificationSoundSettings.stagedFileExtension(
            forSourceExtension: sourceExtension
        )
        let destinationFileName = NotificationSoundSettings.stagedFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let destinationURL = destinationDirectory.appendingPathComponent(
            destinationFileName,
            isDirectory: false
        )
        let sourceMetadata = NotificationSoundSettings.currentMetadata(
            for: sourceURL,
            fileManager: fileManager
        )
        var ownsDestinationArtifact = false

        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            if inFlightConversions[destinationURL] == nil,
               fileManager.fileExists(atPath: destinationURL.path),
               NotificationSoundSettings.loadMetadata(for: destinationURL) != sourceMetadata {
                try? fileManager.removeItem(at: destinationURL)
                ownsDestinationArtifact = true
            }
            if destinationExtension == sourceExtension.lowercased() {
                ownsDestinationArtifact = ownsDestinationArtifact
                    || !isCurrentArtifact(
                        sourceURL: sourceURL,
                        stagedURL: destinationURL,
                        fileManager: fileManager
                    )
                try copyIfNeeded(
                    from: sourceURL,
                    to: destinationURL,
                    fileManager: fileManager
                )
            } else {
                let hadCurrentArtifact = isCurrentArtifact(
                    sourceURL: sourceURL,
                    stagedURL: destinationURL,
                    fileManager: fileManager
                )
                let hadInFlightConversion = inFlightConversions[destinationURL] != nil
                ownsDestinationArtifact = !hadCurrentArtifact && !hadInFlightConversion
                let didCreateArtifact = try await transcodeIfNeeded(
                    from: sourceURL,
                    to: destinationURL,
                    fileManager: fileManager,
                    sourceMetadata: sourceMetadata
                )
                ownsDestinationArtifact = ownsDestinationArtifact || didCreateArtifact
            }
            try Task.checkCancellation()
            if let sourceMetadata {
                try NotificationSoundSettings.saveMetadata(
                    sourceMetadata,
                    for: destinationURL
                )
            }
            pruneArtifactsIfDue(
                in: destinationDirectory,
                preserving: preservedArtifactURLs(
                    destinationURL: destinationURL,
                    sourceURL: sourceURL
                )
            )
            return .success(destinationFileName)
        } catch {
            cleanupFailedArtifact(
                destinationURL: destinationURL,
                sourceURL: sourceURL,
                destinationDirectory: destinationDirectory,
                shouldRemoveDestination: ownsDestinationArtifact
            )
            return .failure(.stagingFailed(
                path: sourcePath,
                details: error.localizedDescription
            ))
        }
    }

    private func preservedArtifactURLs(
        destinationURL: URL,
        sourceURL: URL
    ) -> [URL] {
        [destinationURL, sourceURL]
            + activeArtifactLeaseURLs()
            + inFlightConversions.flatMap { entry in
                [entry.key, entry.value.sourceURL]
            }
    }

    private func retainArtifact(
        for preparedSound: PreparedNotificationSound,
        stagingDirectory: URL?,
        pendingReferenceID: String? = nil
    ) {
        guard case .named(let fileName) = preparedSound else { return }
        let url = NotificationSoundSettings.stagedURL(
            named: fileName,
            stagingDirectory: stagingDirectory
        ).standardizedFileURL
        if let pendingReferenceID {
            purgeExpiredPendingArtifactReferences()
            if pendingArtifactReferences[pendingReferenceID] == nil,
               pendingArtifactReferences.count >= maximumPendingArtifactReferences,
               let oldest = pendingArtifactReferenceExpirations
                    .min(by: { $0.value < $1.value })?.key {
                // A request can still be pending after this bounded table is
                // full. Transfer its artifact ownership to a finite grace
                // lease before evicting the reference, rather than exposing a
                // live notification to the pruning pass with no protection.
                if let evictedURLs = pendingArtifactReferences[oldest] {
                    let expiration = Date().addingTimeInterval(artifactLeaseDuration)
                    for evictedURL in evictedURLs {
                        retainArtifactLease(evictedURL, until: expiration)
                    }
                }
                pendingArtifactReferences.removeValue(forKey: oldest)
                pendingArtifactReferenceExpirations.removeValue(forKey: oldest)
            }
            pendingArtifactReferences[pendingReferenceID, default: []].insert(url)
            pendingArtifactReferenceExpirations[pendingReferenceID] = Date().addingTimeInterval(
                pendingArtifactReferenceGracePeriod
            )
        } else {
            retainArtifactLease(
                url,
                until: Date().addingTimeInterval(artifactLeaseDuration)
            )
        }
    }

    func releasePendingArtifactReference(_ referenceID: String) {
        pendingArtifactReferences.removeValue(forKey: referenceID)
        pendingArtifactReferenceExpirations.removeValue(forKey: referenceID)
    }

    /// Downgrades an uncertain notification-removal reference to a short
    /// lease so a late UserNotifications callback can still find its sound
    /// without retaining the request forever.
    func deferPendingArtifactReference(_ referenceID: String) {
        guard let urls = pendingArtifactReferences.removeValue(forKey: referenceID) else {
            pendingArtifactReferenceExpirations.removeValue(forKey: referenceID)
            return
        }
        pendingArtifactReferenceExpirations.removeValue(forKey: referenceID)
        let expiration = Date().addingTimeInterval(artifactLeaseDuration)
        for url in urls {
            retainArtifactLease(url, until: expiration)
        }
    }

    private func retainArtifactLease(_ url: URL, until expiration: Date) {
        artifactLeaseExpirations[url] = max(
            artifactLeaseExpirations[url] ?? .distantPast,
            expiration
        )
        guard artifactLeaseExpirations.count > maximumArtifactLeases else { return }
        let overflow = artifactLeaseExpirations.count - maximumArtifactLeases
        let expiredCandidates = artifactLeaseExpirations
            .sorted { lhs, rhs in lhs.value < rhs.value }
            .prefix(overflow)
        for (candidate, _) in expiredCandidates {
            artifactLeaseExpirations.removeValue(forKey: candidate)
        }
    }

    private func activeArtifactLeaseURLs() -> [URL] {
        let now = Date()
        purgeExpiredPendingArtifactReferences(now: now)
        artifactLeaseExpirations = artifactLeaseExpirations.filter { $0.value > now }
        return Array(artifactLeaseExpirations.keys)
            + pendingArtifactReferences.values.flatMap(Array.init)
    }

    private func purgeExpiredPendingArtifactReferences(now: Date = Date()) {
        let expired = pendingArtifactReferenceExpirations
            .filter { $0.value <= now }
            .map(\.key)
        for referenceID in expired {
            pendingArtifactReferences.removeValue(forKey: referenceID)
            pendingArtifactReferenceExpirations.removeValue(forKey: referenceID)
        }
    }

    private func cleanupFailedArtifact(
        destinationURL: URL,
        sourceURL: URL,
        destinationDirectory: URL,
        shouldRemoveDestination: Bool
    ) {
        // A shared waiter may still be committing this destination. Only the
        // last failed/canceled transaction is allowed to remove its partial
        // output; otherwise leave the shared artifact for the surviving waiter.
        if shouldRemoveDestination,
           destinationURL.standardizedFileURL != sourceURL.standardizedFileURL,
           inFlightConversions[destinationURL] == nil {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destinationURL)
            try? fileManager.removeItem(
                at: destinationURL.appendingPathExtension("source-metadata")
            )
        }
        pruneArtifactsIfDue(
            in: destinationDirectory,
            preserving: preservedArtifactURLs(
                destinationURL: destinationURL,
                sourceURL: sourceURL
            )
        )
    }

    private func pruneArtifactsIfDue(
        in directory: URL,
        preserving preservedURLs: [URL]
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastArtifactPruneAt) >= artifactPruneInterval else {
            return
        }
        lastArtifactPruneAt = now
        artifactCleaner.prune(in: directory, preserving: preservedURLs)
    }

    private func isCurrentArtifact(
        sourceURL: URL,
        stagedURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: sourceURL.path),
              fileManager.fileExists(atPath: stagedURL.path),
              let sourceMetadata = NotificationSoundSettings.currentMetadata(
                  for: sourceURL,
                  fileManager: fileManager
              ),
              NotificationSoundSettings.loadMetadata(for: stagedURL) == sourceMetadata else {
            return false
        }
        return true
    }

    private func copyIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination else { return }

        if fileManager.fileExists(atPath: destination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: destination.path)
            let sourceSize = sourceAttributes[.size] as? NSNumber
            let destinationSize = destinationAttributes[.size] as? NSNumber
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if sourceSize == destinationSize, sourceDate == destinationDate { return }
            try fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileWriteFileExistsError,
               fileManager.fileExists(atPath: destination.path) {
                return
            }
            throw error
        }
    }

    private func transcodeIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        sourceMetadata: NotificationSoundSourceMetadata?
    ) async throws -> Bool {
        try Task.checkCancellation()
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination else { return false }

        // Never inspect or replace a destination while another transaction is
        // writing it. Join a matching source version; invalidate a stale one,
        // then wait for its process teardown before starting the replacement.
        var mustReconvert = false
        while let existing = inFlightConversions[destination] {
            let sourceVersionMatches = sourceMetadata != nil
                && existing.sourceMetadata == sourceMetadata
            if sourceVersionMatches,
               !existing.cancellationRequested,
               !existing.waiterIDs.isEmpty {
                let result = try await conversionResult(
                    from: source,
                    to: destination,
                    sourceMetadata: sourceMetadata
                )
                try Task.checkCancellation()
                try validateConversionResult(
                    result,
                    destination: destination,
                    fileManager: fileManager
                )
                return false
            }
            if !sourceVersionMatches {
                mustReconvert = true
                invalidateConversion(
                    for: destination,
                    conversionID: existing.id
                )
            } else if existing.cancellationRequested {
                mustReconvert = true
            }
            _ = try? await awaitConversionResult(existing.task)
            removeCompletedConversion(
                for: destination,
                conversionID: existing.id
            )
            try Task.checkCancellation()
        }

        if mustReconvert {
            try? fileManager.removeItem(at: destination)
        } else if fileManager.fileExists(atPath: destination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: destination.path)
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if let sourceDate, let destinationDate, destinationDate >= sourceDate { return false }
            try fileManager.removeItem(at: destination)
        }

        // A conversion may create its destination before it terminates. Join
        // an existing transaction before inspecting that file so another
        // caller never decodes a partially written artifact. Each waiter owns
        // a cancellation token; the shared process is canceled as soon as the
        // last waiter leaves, so evicted feedback cannot keep afconvert alive.
        let result = try await conversionResult(
            from: source,
            to: destination,
            sourceMetadata: sourceMetadata
        )
        try Task.checkCancellation()
        try validateConversionResult(
            result,
            destination: destination,
            fileManager: fileManager
        )
        return true
    }

    private func conversionResult(
        from sourceURL: URL,
        to destinationURL: URL,
        sourceMetadata: NotificationSoundSourceMetadata?
    ) async throws -> NotificationSoundProcessRunner.Result {
        try Task.checkCancellation()
        let waiterID = UUID()
        let conversionTask: Task<NotificationSoundProcessRunner.Result, Error>
        if var existing = inFlightConversions[destinationURL],
           existing.sourceMetadata == sourceMetadata,
           sourceMetadata != nil {
            if existing.waiterIDs.isEmpty {
                defer {
                    removeCompletedConversion(
                        for: destinationURL,
                        conversionID: existing.id
                    )
                }
                return try await awaitConversionResult(existing.task)
            }
            existing.waiterIDs.insert(waiterID)
            conversionTask = existing.task
            inFlightConversions[destinationURL] = existing
        } else {
            let processRunner = self.processRunner
            conversionTask = Task {
                try await processRunner.run(from: sourceURL, to: destinationURL)
            }
            inFlightConversions[destinationURL] = InFlightConversion(
                id: UUID(),
                task: conversionTask,
                sourceURL: sourceURL,
                sourceMetadata: sourceMetadata,
                waiterIDs: [waiterID],
                cancellationRequested: false
            )
        }

        do {
            let result = try await awaitConversionResult(conversionTask)
            removeConversionWaiter(
                for: destinationURL,
                waiterID: waiterID,
                cancellationRequested: false
            )
            return result
        } catch {
            removeConversionWaiter(
                for: destinationURL,
                waiterID: waiterID,
                cancellationRequested: true
            )
            throw error
        }
    }

    /// Awaits a shared conversion while allowing one canceled waiter to leave
    /// immediately without canceling another waiter's process.
    private func awaitConversionResult(
        _ conversionTask: Task<NotificationSoundProcessRunner.Result, Error>
    ) async throws -> NotificationSoundProcessRunner.Result {
        let (stream, continuation) = AsyncThrowingStream<
            NotificationSoundProcessRunner.Result,
            any Error
        >.makeStream()
        let producer = Task {
            do {
                continuation.yield(try await conversionTask.value)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        defer { producer.cancel() }
        guard let result = try await withTaskCancellationHandler(
            operation: { try await stream.first },
            onCancel: { continuation.finish(throwing: CancellationError()) }
        ) else {
            throw CancellationError()
        }
        return result
    }

    private func removeConversionWaiter(
        for destinationURL: URL,
        waiterID: UUID,
        cancellationRequested: Bool
    ) {
        guard var conversion = inFlightConversions[destinationURL],
              conversion.waiterIDs.remove(waiterID) != nil else {
            return
        }
        if conversion.waiterIDs.isEmpty {
            if cancellationRequested, !conversion.cancellationRequested {
                conversion.cancellationRequested = true
                inFlightConversions[destinationURL] = conversion
                scheduleConversionCleanup(
                    for: destinationURL,
                    conversion: conversion
                )
                conversion.task.cancel()
            } else if !cancellationRequested {
                inFlightConversions.removeValue(forKey: destinationURL)
            }
        } else {
            inFlightConversions[destinationURL] = conversion
        }
    }

    private func invalidateConversion(
        for destinationURL: URL,
        conversionID: UUID
    ) {
        guard var conversion = inFlightConversions[destinationURL],
              conversion.id == conversionID else {
            return
        }
        conversion.waiterIDs.removeAll()
        guard !conversion.cancellationRequested else { return }
        conversion.cancellationRequested = true
        inFlightConversions[destinationURL] = conversion
        scheduleConversionCleanup(
            for: destinationURL,
            conversion: conversion
        )
        conversion.task.cancel()
    }

    private func scheduleConversionCleanup(
        for destinationURL: URL,
        conversion: InFlightConversion
    ) {
        let conversionID = conversion.id
        let task = conversion.task
        Task { [weak self] in
            let result = await task.result
            await self?.finishCompletedConversion(
                for: destinationURL,
                conversionID: conversionID,
                result: result
            )
        }
    }

    private func removeCompletedConversion(
        for destinationURL: URL,
        conversionID: UUID
    ) {
        guard let conversion = inFlightConversions[destinationURL],
              conversion.id == conversionID,
              conversion.waiterIDs.isEmpty else {
            return
        }
        inFlightConversions.removeValue(forKey: destinationURL)
    }

    private func finishCompletedConversion(
        for destinationURL: URL,
        conversionID: UUID,
        result: Result<NotificationSoundProcessRunner.Result, Error>
    ) {
        guard let conversion = inFlightConversions[destinationURL],
              conversion.id == conversionID else {
            return
        }
        let failed = switch result {
        case .failure:
            true
        case .success(let processResult):
            processResult.terminationStatus != 0
        }
        if failed || conversion.cancellationRequested {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destinationURL)
            try? fileManager.removeItem(
                at: destinationURL.appendingPathExtension("source-metadata")
            )
        }
        removeCompletedConversion(
            for: destinationURL,
            conversionID: conversionID
        )
    }

    private func validateConversionResult(
        _ result: NotificationSoundProcessRunner.Result,
        destination: URL,
        fileManager: FileManager
    ) throws {
        guard result.terminationStatus == 0 else {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            let description = result.errorOutput
                ?? "afconvert failed with exit code \(result.terminationStatus)"
            throw NSError(
                domain: "NotificationSoundSettings",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    private func isDecodableSoundFile(at url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  file.processingFormat.channelCount > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: 1
                  ) else {
                return false
            }
            try file.read(into: buffer, frameCount: 1)
            return buffer.frameLength == 1
        } catch {
            return false
        }
    }

    private func log(_ issue: PreparationIssue) {
        notificationSoundStagerLogger.error(
            "Notification custom sound unavailable: \(issue.logMessage, privacy: .private)"
        )
    }
}
