import Darwin
import Foundation

/// Minimal self-exec mode that creates a private plugin process group before
/// replacing itself with the existing launch-gate shell command.
struct CmuxPluginProcessLauncherMode {
    private let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    /// Runs the launcher when its private marker is present.
    ///
    /// - Returns: `nil` for a normal app launch, or a failure status when group
    ///   setup/exec failed. A successful shell exec never returns.
    func runIfRequested() -> Int32? {
        guard arguments.count >= 3,
              arguments[1] == "--cmux-plugin-launcher" else {
            return nil
        }
        guard setpgid(0, 0) == 0 else { return 126 }
        let shellArguments = ["/bin/sh"] + arguments.dropFirst(2)
        return withCStringArray(Array(shellArguments)) { argv in
            "/bin/sh".withCString { path in
                execv(path, argv)
            }
        } == 0 ? 0 : 126
    }

    private func withCStringArray<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.dropLast().forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }
}
