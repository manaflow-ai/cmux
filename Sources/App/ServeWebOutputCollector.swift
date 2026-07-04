import Foundation

final class ServeWebOutputCollector {
    private static let portCollisionScanTailLength = 64

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = ""
    private var portCollisionScanTail = ""
    private var resolvedURL: URL?
    private var portCollisionDetected = false
    private var didSignal = false

    var webUIURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedURL
    }

    var sawPortCollision: Bool {
        lock.lock()
        defer { lock.unlock() }
        return portCollisionDetected
    }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let portCollisionScanText = portCollisionScanTail + text
        if Self.textIndicatesPortCollision(portCollisionScanText) {
            portCollisionDetected = true
        }
        portCollisionScanTail = String(portCollisionScanText.suffix(Self.portCollisionScanTailLength))
        guard resolvedURL == nil else { return }
        outputBuffer.append(text)
        while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
            let line = String(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            guard let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: line) else {
                continue
            }
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
            if !didSignal {
                didSignal = true
                semaphore.signal()
            }
            return
        }
    }

    func markProcessExited() {
        lock.lock()
        defer { lock.unlock() }
        if resolvedURL == nil, !outputBuffer.isEmpty,
           let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: outputBuffer) {
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
        }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    func waitForURL(timeoutSeconds: TimeInterval) -> Bool {
        if webUIURL != nil { return true }
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return webUIURL != nil
    }

    private static func textIndicatesPortCollision(_ text: String) -> Bool {
        let lowercasedText = text.lowercased()
        return lowercasedText.contains("eaddrinuse")
            || lowercasedText.contains("address already in use")
            || lowercasedText.contains("port is already in use")
    }
}
