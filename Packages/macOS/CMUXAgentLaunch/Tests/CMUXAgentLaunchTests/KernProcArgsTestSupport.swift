func kernProcArgs(
    arguments: [String],
    environmentEntries: [String]
) -> [UInt8] {
    var argc = Int32(arguments.count).littleEndian
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    appendCString(arguments.first ?? "", to: &bytes)
    bytes.append(0)
    for argument in arguments {
        appendCString(argument, to: &bytes)
    }
    for entry in environmentEntries {
        appendCString(entry, to: &bytes)
    }
    return bytes
}

private func appendCString(_ value: String, to bytes: inout [UInt8]) {
    bytes.append(contentsOf: value.utf8)
    bytes.append(0)
}
