import Foundation

final class ServeWebOutputCollector {
    private static let maximumBufferedOutputCharacters = 8192

    private let stateQueue = DispatchQueue(label: "cmux.vscode.serveWeb.output")
    private let urlBuilder = VSCodeServeWebURLBuilder()
    private let onCompletion: (URL?) -> Void
    private var outputBuffer = ""
    private var resolvedURL: URL?
    private var didComplete = false

    init(onCompletion: @escaping (URL?) -> Void = { _ in }) {
        self.onCompletion = onCompletion
    }

    var webUIURL: URL? {
        stateQueue.sync(execute: {
            resolvedURL
        })
    }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let completion = stateQueue.sync(execute: { () -> (shouldComplete: Bool, url: URL?) in
            guard resolvedURL == nil, !didComplete else { return (false, nil) }
            outputBuffer.append(text)
            while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
                let line = String(outputBuffer[..<newlineIndex])
                outputBuffer.removeSubrange(...newlineIndex)
                guard let parsedURL = urlBuilder.extractWebUIURL(from: line) else {
                    continue
                }
                resolvedURL = parsedURL
                outputBuffer.removeAll(keepingCapacity: false)
                return completeIfNeededLocked(with: parsedURL)
            }
            trimOutputBufferIfNeeded()
            return (false, nil)
        })
        if completion.shouldComplete {
            onCompletion(completion.url)
        }
    }

    func markProcessExited() {
        let completion = stateQueue.sync(execute: { () -> (shouldComplete: Bool, url: URL?) in
            if resolvedURL == nil, !outputBuffer.isEmpty,
               let parsedURL = urlBuilder.extractWebUIURL(from: outputBuffer) {
                resolvedURL = parsedURL
                outputBuffer.removeAll(keepingCapacity: false)
            }
            return completeIfNeededLocked(with: resolvedURL)
        })
        if completion.shouldComplete {
            onCompletion(completion.url)
        }
    }

    private func completeIfNeededLocked(with url: URL?) -> (shouldComplete: Bool, url: URL?) {
        guard !didComplete else { return (false, nil) }
        didComplete = true
        return (true, url)
    }

    private func trimOutputBufferIfNeeded() {
        let overflow = outputBuffer.count - Self.maximumBufferedOutputCharacters
        if overflow > 0 {
            outputBuffer.removeFirst(overflow)
        }
    }
}
