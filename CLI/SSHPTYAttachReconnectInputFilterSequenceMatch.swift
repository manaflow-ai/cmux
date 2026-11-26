enum SSHPTYAttachReconnectInputFilterSequenceMatch {
    case strip(length: Int)
    case incomplete
    case passThrough
}
