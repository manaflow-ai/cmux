import Foundation

final class ServeWebOutputCollector {
    private static let maximumBufferedOutputCharacters = 8192

    private let stateQueue = DispatchQueue(label: "cmux.vscode.serveWeb.output")
    private let completionGroup = DispatchGroup()
    private let urlBuilder = VSCodeServeWebURLBuilder()
    private var outputBuffer = ""
    private var resolvedURL: URL?
    private var didSignal = false

    init() {
        completionGroup.enter()
    }

    var webUIURL: URL? {
        stateQueue.sync(execute: {
            resolvedURL
        })
    }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        stateQueue.sync(execute: {
            guard resolvedURL == nil else { return }
            outputBuffer.append(text)
            while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
                let line = String(outputBuffer[..<newlineIndex])
                outputBuffer.removeSubrange(...newlineIndex)
                guard let parsedURL = urlBuilder.extractWebUIURL(from: line) else {
                    continue
                }
                resolvedURL = parsedURL
                outputBuffer.removeAll(keepingCapacity: false)
                signalCompletionIfNeeded()
                return
            }
            trimOutputBufferIfNeeded()
        })
    }

    func markProcessExited() {
        stateQueue.sync(execute: {
            if resolvedURL == nil, !outputBuffer.isEmpty,
               let parsedURL = urlBuilder.extractWebUIURL(from: outputBuffer) {
                resolvedURL = parsedURL
                outputBuffer.removeAll(keepingCapacity: false)
            }
            signalCompletionIfNeeded()
        })
    }

    func waitForURL(timeoutSeconds: TimeInterval) -> Bool {
        if webUIURL != nil { return true }
        _ = completionGroup.wait(timeout: .now() + timeoutSeconds)
        return webUIURL != nil
    }

    private func signalCompletionIfNeeded() {
        guard !didSignal else { return }
        didSignal = true
        completionGroup.leave()
    }

    private func trimOutputBufferIfNeeded() {
        let overflow = outputBuffer.count - Self.maximumBufferedOutputCharacters
        if overflow > 0 {
            outputBuffer.removeFirst(overflow)
        }
    }
}
