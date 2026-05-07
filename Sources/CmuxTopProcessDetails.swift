import Darwin
import Foundation
import ObjectiveC.runtime
import WebKit

private nonisolated let cmuxTopPIDPathBufferSize = 4096

nonisolated extension CmuxTopProcessSnapshot {
    static func taskInfo(for pid: Int) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    static func processName(pid: Int, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN + 1))
        let length = proc_name(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: cmuxTopPIDPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let endIndex = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<endIndex], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}

enum CmuxWebContentProcessIdentifier {
    static func pid(for webView: WKWebView) -> Int? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            return nil
        }

        typealias WebProcessIdentifierFn = @convention(c) (AnyObject, Selector) -> Int32
        let implementation = method_getImplementation(method)
        let pid = unsafeBitCast(implementation, to: WebProcessIdentifierFn.self)(webView, selector)
        return pid > 0 ? Int(pid) : nil
    }
}
