import Foundation

extension TerminalController {
    /// Lists a stable page of direct child directories for the iOS task
    /// composer while preserving typed filesystem failures on the RPC wire.
    func v2MobileDirectoryList(
        params: [String: Any],
        filesystemJobQuota: MobileTaskFilesystemJobQuota
    ) async -> V2CallResult {
        guard let path = params["path"] as? String,
              let offset = params["offset"] as? Int,
              let limit = params["limit"] as? Int,
              offset >= 0,
              (1...MobileTaskDirectoryListService.maximumPageSize).contains(limit) else {
            return .err(
                code: "invalid_params",
                message: "Directory path, nonnegative offset, and page limit from 1 to 100 are required",
                data: nil
            )
        }
        guard filesystemJobQuota.acquire() else {
            return .err(
                code: "busy",
                message: "Too many filesystem requests are already in progress",
                data: nil
            )
        }
        defer { filesystemJobQuota.release() }

        do {
            let page = try await MobileTaskDirectoryListService().list(
                path: path,
                offset: offset,
                limit: limit
            )
            let entries: [[String: Any]] = page.entries.map { entry in
                [
                    "name": entry.name,
                    "path": entry.path,
                    "is_hidden": entry.isHidden,
                    "is_package": entry.isPackage,
                    "is_symbolic_link": entry.isSymbolicLink,
                    "is_readable": entry.isReadable,
                ]
            }
            return .ok([
                "current_path": page.currentPath,
                "parent_path": page.parentPath ?? NSNull(),
                "entries": entries,
                "offset": page.offset,
                "limit": page.limit,
                "total_count": page.totalCount,
                "next_offset": page.nextOffset ?? NSNull(),
            ])
        } catch let error as MobileTaskDirectoryListServiceError {
            switch error {
            case .invalidRequest:
                return .err(code: "invalid_params", message: "Directory pagination values are invalid", data: nil)
            case .invalidPath:
                return .err(code: "invalid_params", message: "Directory path must be absolute or start with ~", data: nil)
            case .notFound:
                return .err(code: "directory_not_found", message: "Directory does not exist", data: nil)
            case .notDirectory:
                return .err(code: "not_a_directory", message: "Path is not a directory", data: nil)
            case .permissionDenied:
                return .err(code: "permission_denied", message: "Permission to read the directory was denied", data: nil)
            case .unreadable:
                return .err(code: "directory_unreadable", message: "Directory cannot be read", data: nil)
            }
        } catch is CancellationError {
            return .err(code: "cancelled", message: "Directory listing was cancelled", data: nil)
        } catch {
            return .err(code: "internal_error", message: "Directory listing failed", data: nil)
        }
    }
}
