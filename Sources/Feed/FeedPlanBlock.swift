enum FeedPlanBlock {
    case heading(String)
    case paragraph(String)
    case numbered([FeedPlanNumberedItem])
    case bulleted([String])
}
