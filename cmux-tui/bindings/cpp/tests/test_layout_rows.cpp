#include "test.hpp"
#include "cmux/resource.hpp"

#include <string>
#include <variant>

namespace {
// A rows-v1 layout document: column 0 has two rows (row 2's row_id is its
// compat chain split), column 1 has one row and no rows field.
std::string layout_with_rows(const std::string& rows) {
    return std::string(
        "{\"version\":1,\"screen_id\":\"screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
        "\"active_pane_id\":\"pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"zoomed_pane_id\":null,"
        "\"root\":{\"kind\":\"viewport\",\"base_width\":0.5,\"columns\":["
        "{\"column_id\":\"split_cccccccccccccccccccccccccccccccc\",\"width\":0.5,"
        "\"root\":{\"kind\":\"split\",\"split_id\":\"split_dddddddddddddddddddddddddddddddd\","
        "\"direction\":\"vertical\",\"ratio\":0.6,"
        "\"first\":{\"kind\":\"leaf\",\"pane_id\":\"pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"tab_ids\":[]},"
        "\"second\":{\"kind\":\"leaf\",\"pane_id\":\"pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"tab_ids\":[]}},"
        "\"rows\":") + rows + "},"
        "{\"column_id\":\"split_ffffffffffffffffffffffffffffffff\",\"width\":0.5,"
        "\"root\":{\"kind\":\"leaf\",\"pane_id\":\"pane_cccccccccccccccccccccccccccccccc\",\"tab_ids\":[]}}]}}";
}

const std::string kRows =
    "[{\"row_id\":\"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"height\":600},"
    "{\"row_id\":\"split_dddddddddddddddddddddddddddddddd\",\"height\":400}]";

cmux::Result<cmux::LayoutDocument> decode(const std::string& rows) {
    auto parsed = cmux::Json::parse(layout_with_rows(rows));
    if (!parsed) return parsed.error();
    return cmux::detail::decode_value<cmux::LayoutDocument>(parsed.value());
}
}  // namespace

TEST("layout documents decode a column's rows") {
    const auto decoded = decode(kRows);
    CHECK(decoded);
    const auto& viewport = std::get<cmux::LayoutViewport>(decoded.value().root.value);
    const auto& rows = viewport.columns.at(0).rows;
    CHECK_EQ(rows.size(), static_cast<std::size_t>(2));
    CHECK_EQ(rows.at(0).height, static_cast<std::uint16_t>(600));
    CHECK_EQ(rows.at(1).height, static_cast<std::uint16_t>(400));
    CHECK(rows.at(1).row_id.has_value());
    CHECK_EQ(rows.at(1).row_id->value(), std::string("split_dddddddddddddddddddddddddddddddd"));
    CHECK(viewport.columns.at(1).rows.empty());
    const auto first = decode(
        "[{\"height\":500},{\"row_id\":\"split_dddddddddddddddddddddddddddddddd\",\"height\":400}]");
    CHECK(first);
    CHECK(!std::get<cmux::LayoutViewport>(first.value().root.value).columns.at(0).rows.at(0).row_id);
}

TEST("layout documents refuse bad rows") {
    for (const auto& bad : {
             std::string("[{\"row_id\":\"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"height\":600,\"width\":1},"
                         "{\"row_id\":\"split_dddddddddddddddddddddddddddddddd\",\"height\":400}]"),
             std::string("[{\"row_id\":\"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"height\":50},"
                         "{\"row_id\":\"split_dddddddddddddddddddddddddddddddd\",\"height\":400}]"),
             std::string("[{\"row_id\":\"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"},"
                         "{\"row_id\":\"split_dddddddddddddddddddddddddddddddd\",\"height\":400}]"),
             std::string("\"rows\""),
         }) {
        CHECK(!decode(bad));
    }
}
