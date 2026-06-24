import Foundation

struct UITestLaunchArguments {
    let arguments: [String]

    func value(for key: String) -> String? {
        let dashedKey = "-\(key)"
        for (index, argument) in arguments.enumerated() {
            if argument == dashedKey,
               index + 1 < arguments.count {
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            if argument.hasPrefix("\(key)=") {
                let value = String(argument.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            if argument.hasPrefix("\(dashedKey)=") {
                let value = String(argument.dropFirst(dashedKey.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
