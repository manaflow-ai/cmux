public import CmuxNextBrowserImport
public import CmuxNextDaemon

extension BrowserDataReader {
    /// The browser import's reader on a daemon: `browser_import.read` (``BrowserImportClient``)
    /// on the connection `connection` gives, refused when there is none.
    public static func daemon(_ connection: @escaping @Sendable () async -> DaemonConnection?) -> BrowserDataReader {
        BrowserDataReader { request in
            guard let connection = await connection() else { throw DaemonError.notConnected }
            return try await BrowserImportClient(connection: connection).read(request)
        }
    }
}
