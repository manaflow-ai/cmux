import Darwin
import Dispatch
import Foundation

private func uiLayerSignalHandler(_: Int32) {}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

@main
@MainActor
struct UiLayerSourceWatcherMain {
    static func main() {
        do {
            let options = try WatchOptions(arguments: CommandLine.arguments)
            SourceSupervisor(options: options).run()
        } catch {
            writeError("ui-layer watcher: \(error.localizedDescription)\n")
            exit(2)
        }
    }
}

private struct WatchOptions {
    let package: URL
    let watchRoots: [URL]
    let hostArguments: [String]

    init(arguments: [String]) throws {
        var packagePath: String?
        var watchRoots: [URL] = []
        var hostArguments: [String] = []
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--package", index + 1 < arguments.count {
                packagePath = arguments[index + 1]
                index += 2
            } else if arguments[index] == "--watch-root", index + 1 < arguments.count {
                watchRoots.append(URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL)
                index += 2
            } else {
                hostArguments.append(arguments[index])
                index += 1
            }
        }
        guard let packagePath, !packagePath.isEmpty else { throw WatchError.missingPackage }
        package = URL(fileURLWithPath: packagePath).standardizedFileURL
        self.watchRoots = [package] + watchRoots
        self.hostArguments = hostArguments
    }
}

private enum WatchError: LocalizedError {
    case missingPackage

    var errorDescription: String? {
        switch self {
        case .missingPackage: "--package is required"
        }
    }
}

@MainActor
private final class SourceSupervisor {
    private let options: WatchOptions
    private var child: Process?
    private var watchers: [any DispatchSourceFileSystemObject] = []
    private var restartPending = false
    private var signalSources: [any DispatchSourceSignal] = []

    init(options: WatchOptions) {
        self.options = options
    }

    func run() {
        rebuildWatchers()
        installSignalHandlers()
        startChild()
        dispatchMain()
    }

    private func startChild() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift", "run", "--package-path", options.package.path,
            "cmux-ui-layer", "--",
        ] + options.hostArguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in self?.childExited(status) }
        }
        do {
            try process.run()
            child = process
        } catch {
            writeError("ui-layer watcher: could not start host: \(error.localizedDescription)\n")
            exit(1)
        }
    }

    private func childExited(_ status: Int32) {
        child = nil
        guard restartPending else { exit(status == 0 ? 0 : Int32(status)) }
        restartPending = false
        rebuildWatchers()
        startChild()
    }

    private func sourceChanged(_ url: URL) {
        guard !restartPending else { return }
        restartPending = true
        writeError("ui-layer.reload path=\(url.path) requested_at_ns=\(DispatchTime.now().uptimeNanoseconds)\n")
        child?.terminate()
    }

    private func rebuildWatchers() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll(keepingCapacity: true)
        watch(options.package.appendingPathComponent("Package.swift"))
        for root in options.watchRoots {
            watch(root)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true || (values?.isRegularFile == true && url.pathExtension == "swift") {
                    watch(url)
                }
            }
        }
    }

    private func watch(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.sourceChanged(url) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers.append(source)
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            // A caught signal is reset to the default disposition across exec;
            // SIG_IGN would be inherited by the Swift host and make terminate()
            // unable to stop it for a source reload.
            signal(signalNumber, uiLayerSignalHandler)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.shutdown() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown() {
        watchers.forEach { $0.cancel() }
        child?.terminate()
        exit(0)
    }
}
