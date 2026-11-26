import CryptoKit
import Foundation

struct SimulatorBuildInputs: Equatable, Sendable {
    let sources: [SimulatorBuildSource]
    let compileArguments: [String]
    let sdk: SimulatorSDKIdentity

    var cacheKey: String {
        var data = Data()
        appendSimulatorCacheField("cmux-simulator-build-cache-v1", to: &data)
        appendSimulatorCacheField(sdk.path, to: &data)
        appendSimulatorCacheField(sdk.version, to: &data)
        appendSimulatorCacheField(sdk.buildVersion, to: &data)
        appendSimulatorCacheField(sdk.compilerVersion, to: &data)
        appendSimulatorCacheField(sdk.settingsDigest, to: &data)
        for argument in compileArguments {
            appendSimulatorCacheField(argument, to: &data)
        }
        for source in sources {
            appendSimulatorCacheField(source.name, to: &data)
            appendSimulatorCacheField(source.data, to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func appendSimulatorCacheField(_ value: String, to data: inout Data) {
    appendSimulatorCacheField(Data(value.utf8), to: &data)
}

private func appendSimulatorCacheField(_ value: Data, to data: inout Data) {
    var count = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    data.append(value)
}
