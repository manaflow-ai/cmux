public import CMUXMobileCore
public import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    /// Lists one stable page of direct child directories on a selected Mac.
    ///
    /// This probes the method even when the cached capability set is stale. A
    /// genuinely older Mac returns ``MobileTaskDirectoryListFailure/unsupported``
    /// so the UI can explain that browsing requires a Mac update.
    ///
    /// - Parameters:
    ///   - macDeviceID: The paired Mac that owns the filesystem.
    ///   - instanceTag: Exact paired app instance to query, or `nil` for
    ///     legacy device-level routing.
    ///   - path: An absolute path, `~`, or a path beginning with `~/`.
    ///   - offset: A nonnegative entry offset in the directory's stable order.
    ///   - limit: A page size from `1` through
    ///     ``MobileTaskDirectoryListRequest/maximumPageSize``.
    /// - Returns: A validated page, or a typed user-actionable failure.
    public func listTaskDirectories(
        macDeviceID: String,
        instanceTag: String? = nil,
        path: String,
        offset: Int = 0,
        limit: Int = MobileTaskDirectoryListRequest.defaultPageSize
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        let diagnosticStartedAt = appDiagnosticNow()
        recordAppEvent(
            .taskDirectorySearchStarted,
            correlationID: macDeviceID
        )
        func finish(
            _ result: Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>
        ) -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
            switch result {
            case .success(let response):
                recordAppEvent(
                    .taskDirectorySearchSucceeded,
                    correlationID: macDeviceID,
                    startedAt: diagnosticStartedAt,
                    count: response.entries.count
                )
            case .failure(let failure):
                recordAppEvent(
                    .taskDirectorySearchFailed,
                    correlationID: macDeviceID,
                    startedAt: diagnosticStartedAt,
                    failure: failure.diagnosticFailureKind
                )
            }
            return result
        }
        guard let listRequest = MobileTaskDirectoryListRequest(
            path: path,
            offset: offset,
            limit: limit
        ) else {
            return finish(.failure(.invalidPath))
        }

        if !matchesForegroundPairing(macDeviceID: macDeviceID, instanceTag: instanceTag)
            || remoteClient == nil {
            guard await switchToMac(macDeviceID: macDeviceID, instanceTag: instanceTag) else {
                return finish(.failure(Task.isCancelled ? .cancelled : .unavailable))
            }
        }
        guard !Task.isCancelled,
              matchesForegroundPairing(macDeviceID: macDeviceID, instanceTag: instanceTag),
              let client = remoteClient else {
            return finish(.failure(.cancelled))
        }
        let generation = connectionGeneration

        do {
            let requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.directory.list",
                params: [
                    "path": listRequest.path,
                    "offset": listRequest.offset,
                    "limit": listRequest.limit,
                ]
            )
            let data = try await client.sendRequest(
                requestData,
                timeoutNanoseconds: 4_000_000_000
            )
            guard !Task.isCancelled,
                  matchesForegroundPairing(macDeviceID: macDeviceID, instanceTag: instanceTag) else {
                return finish(.failure(.cancelled))
            }
            return finish(.success(try MobileTaskDirectoryListResponse.decode(data)))
        } catch let error as MobileShellConnectionError {
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            switch error {
            case let .rpcError(code, _) where [
                "method_not_found",
                "unknown_method",
                "unsupported_method",
            ].contains(code?.lowercased() ?? ""):
                return finish(.failure(.unsupported))
            case .requestTimedOut,
                 .connectAttemptGated,
                 .rpcError("request_timeout", _):
                return finish(.failure(.timedOut))
            case .authorizationFailed,
                 .accountMismatch,
                 .rpcError("unauthorized", _),
                 .rpcError("account_mismatch", _),
                 .rpcError("forbidden", _):
                return finish(.failure(.authorizationRequired))
            case .rpcError("invalid_params", _):
                return finish(.failure(.invalidPath))
            case .rpcError("directory_not_found", _):
                return finish(.failure(.notFound))
            case .rpcError("not_a_directory", _):
                return finish(.failure(.notDirectory))
            case .rpcError("permission_denied", _):
                return finish(.failure(.permissionDenied))
            case .rpcError("directory_unreadable", _):
                return finish(.failure(.unreadable))
            case .rpcError("cancelled", _):
                return finish(.failure(.cancelled))
            case .connectionClosed,
                 .transportWriteTimedOut,
                 .routeCleanupBlocked,
                 .insecureManualRoute,
                 .attachTicketExpired:
                return finish(.failure(.unavailable))
            case .invalidResponse,
                 .rpcError:
                return finish(.failure(.rejected))
            }
        } catch is CancellationError {
            return finish(.failure(.cancelled))
        } catch {
            return finish(.failure(.rejected))
        }
    }
}
