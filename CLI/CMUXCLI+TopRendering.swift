import Foundation

extension CMUXCLI {
    func topLabelText(_ raw: String?) -> String {
        guard let raw else { return "" }
        let scalars = Array(raw.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value

            if value == 0x1B {
                index = topIndexAfterEscapeSequence(in: scalars, from: index)
                continue
            }
            if value == 0x9B {
                index += 1
                while index < scalars.count {
                    let final = scalars[index].value
                    index += 1
                    if final >= 0x40 && final <= 0x7E {
                        break
                    }
                }
                continue
            }
            if value == 0x09 || value == 0x0A || value == 0x0D {
                output.append(UnicodeScalar(0x20)!)
            } else if value >= 0x20 && value != 0x7F {
                output.append(scalar)
            }
            index += 1
        }

        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func topIndexAfterEscapeSequence(in scalars: [Unicode.Scalar], from startIndex: Int) -> Int {
        var index = startIndex + 1
        guard index < scalars.count else { return index }

        let introducer = scalars[index].value
        if introducer == 0x5B {
            index += 1
            while index < scalars.count {
                let value = scalars[index].value
                index += 1
                if value >= 0x40 && value <= 0x7E {
                    break
                }
            }
            return index
        }

        if introducer == 0x5D {
            index += 1
            while index < scalars.count {
                if scalars[index].value == 0x07 {
                    return index + 1
                }
                if scalars[index].value == 0x1B,
                   index + 1 < scalars.count,
                   scalars[index + 1].value == 0x5C {
                    return index + 2
                }
                index += 1
            }
            return index
        }

        return index + 1
    }
}
