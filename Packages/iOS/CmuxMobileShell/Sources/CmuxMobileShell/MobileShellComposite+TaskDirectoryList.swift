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
    ///   - path: An absolute path, `~`, or a path beginning with `~/`.
    ///   - offset: A nonnegative entry offset in the directory's stable order.
    ///   - limit: A page size from `1` through
    ///     ``MobileTaskDirectoryListRequest/maximumPageSize``.
    /// - Returns: A validated page, or a typed user-actionable failure.
    public func listTaskDirectories(
        macDeviceID: String,
        path: String,
        offset: Int = 0,
        limit: Int = MobileTaskDirectoryListRequest.defaultPageSize
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        guard let listRequest = MobileTaskDirectoryListRequest(
            path: path,
            offset: offset,
            limit: limit
        ) else {
            return .failure(.invalidPath)
        }

        if macDeviceID != foregroundMacDeviceID || remoteClient == nil {
            guard await switchToMac(macDeviceID: macDeviceID) else {
                return .failure(Task.isCancelled ? .cancelled : .unavailable)
            }
        }
        guard !Task.isCancelled, foregroundMacDeviceID == macDeviceID,
              let client = remoteClient else {
            return .failure(.cancelled)
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
            guard !Task.isCancelled, foregroundMacDeviceID == macDeviceID else {
                return .failure(.cancelled)
            }
            return .success(try MobileTaskDirectoryListResponse.decode(data))
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
                return .failure(.unsupported)
            case .requestTimedOut,
                 .rpcError("request_timeout", _):
                return .failure(.timedOut)
            case .authorizationFailed,
                 .accountMismatch,
                 .rpcError("unauthorized", _),
                 .rpcError("account_mismatch", _),
                 .rpcError("forbidden", _):
                return .failure(.authorizationRequired)
            case .rpcError("invalid_params", _):
                return .failure(.invalidPath)
            case .rpcError("directory_not_found", _):
                return .failure(.notFound)
            case .rpcError("not_a_directory", _):
                return .failure(.notDirectory)
            case .rpcError("permission_denied", _):
                return .failure(.permissionDenied)
            case .rpcError("directory_unreadable", _):
                return .failure(.unreadable)
            case .rpcError("cancelled", _):
                return .failure(.cancelled)
            case .connectionClosed,
                 .transportWriteTimedOut,
                 .insecureManualRoute,
                 .attachTicketExpired:
                return .failure(.unavailable)
            case .invalidResponse,
                 .rpcError:
                return .failure(.rejected)
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.rejected)
        }
    }
}
