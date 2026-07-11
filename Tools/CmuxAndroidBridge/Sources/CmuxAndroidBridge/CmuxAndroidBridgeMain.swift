import Darwin
import Foundation

@main
struct CmuxAndroidBridgeMain {
    static func main() async {
        do {
            let arguments = try BridgeArguments.parse(Array(CommandLine.arguments.dropFirst()))
            try await BridgeRuntime(arguments: arguments).run()
        } catch {
            let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("cmux-android-bridge: \(message)\n".utf8))
            exit(1)
        }
    }
}
