import Foundation

enum CmuxRunURLParseError: Error, Equatable {
    case unsupportedURLShape
    case missingParameter(String)
    case emptyParameter(String)
    case valueTooLong(parameter: String, maxLength: Int)
    case unsafeCharacters(String)
    case duplicateParameter(String)
    case unsupportedParameter(String)
    case invalidPlacement(String)
    case invalidDirection(String)
    case invalidIdentifier(String)
    case invalidTargetCombination
    case multipleLinks
}
