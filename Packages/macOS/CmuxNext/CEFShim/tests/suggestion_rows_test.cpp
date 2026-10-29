// Cases of the SUGGESTIONS event's JSON (CEFShim/src/suggestion_rows.h):
// scripts/cmux-next/test-shim-suggestion-rows-cpp.sh. The rows the fork shows
// reach cmux's list (task 061) whole and escaped; a
// struct older than API 31 or rows without data send nothing.
#include "../src/suggestion_rows.h"

#include <cstdio>
#include <string>
#include <vector>

#ifdef CMUX_CHECK_FORK_HEADER
// With a fork checkout (CMUX_CEF_FORK, see the script): the copies have
// include/cef_cmux.h's layouts.
#include "include/cef_cmux.h"

#define SAME(T, U)                                   \
  static_assert(sizeof(T) == sizeof(U), #T " size"); \
  static_assert(alignof(T) == alignof(U), #T " alignment")
#define FIELD(T, U, f) static_assert(offsetof(T, f) == offsetof(U, f), #T "." #f)
SAME(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, type);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, main_text);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, minor_text);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, label);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, voice_over);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, selectable);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, acceptable);
FIELD(cmux_shim::ForkSuggestionRow, cmux_suggestion_row_t, loading);
SAME(cmux_shim::ForkSuggestions, cmux_suggestions_t);
FIELD(cmux_shim::ForkSuggestions, cmux_suggestions_t, token);
FIELD(cmux_shim::ForkSuggestions, cmux_suggestions_t, x);
FIELD(cmux_shim::ForkSuggestions, cmux_suggestions_t, height);
FIELD(cmux_shim::ForkSuggestions, cmux_suggestions_t, rtl);
FIELD(cmux_shim::ForkSuggestions, cmux_suggestions_t, selected);
FIELD(cmux_shim::ForkSuggestions, cmux_suggestions_t, rows);
FIELD(cmux_shim::ForkSuggestions, cmux_suggestions_t, row_count);
SAME(cmux_shim::ForkSuggestionHandler, cmux_suggestion_handler_t);
FIELD(cmux_shim::ForkSuggestionHandler, cmux_suggestion_handler_t, show);
FIELD(cmux_shim::ForkSuggestionHandler, cmux_suggestion_handler_t, select);
FIELD(cmux_shim::ForkSuggestionHandler, cmux_suggestion_handler_t, hide);
FIELD(cmux_shim::ForkSuggestionHandler, cmux_suggestion_handler_t, announce);
FIELD(cmux_shim::ForkSuggestionHandler, cmux_suggestion_handler_t, context);
static_assert(CMUX_SUGGESTION_ROW_ENTRY == 0 && CMUX_SUGGESTION_ROW_SEPARATOR == 1 && CMUX_SUGGESTION_ROW_TITLE == 2 &&
                  CMUX_SUGGESTION_ROW_FOOTER == 3,
              "row kinds (ChromiumHostSuggestions.Row.Kind)");
static_assert(CMUX_SUGGESTION_SHOWN == 0 && CMUX_SUGGESTION_SELECT == 1 && CMUX_SUGGESTION_ACCEPT == 2 &&
                  CMUX_SUGGESTION_REMOVE == 3 && CMUX_SUGGESTION_DISMISS == 4,
              "actions (cmux_shim_suggestion_action_t)");
#endif

namespace {
int failures = 0;
void Expect(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

cmux_shim::ForkSuggestions Shown(const cmux_shim::ForkSuggestionRow* rows, int count) {
  cmux_shim::ForkSuggestions suggestions{};
  suggestions.size = sizeof(cmux_shim::ForkSuggestions);
  suggestions.token = 41;
  suggestions.x = 10;
  suggestions.y = 20;
  suggestions.width = 240;
  suggestions.height = 32;
  suggestions.selected = -1;
  suggestions.rows = rows;
  suggestions.row_count = count;
  return suggestions;
}
}  // namespace

int main() {
  using cmux_shim::ForkSuggestionRow;
  using cmux_shim::SuggestionsJSON;

  const ForkSuggestionRow password[] = {
      {0, 21, "ada@example.com", "", "\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2", "", 1, 1, 0},
      {1, 4, "", "", "", "", 0, 0, 0},
      {3, 26, "Manage passwords\xE2\x80\xA6", "", "", "", 1, 1, 0},
  };
  cmux_shim::ForkSuggestions shown = Shown(password, 3);
  Expect(SuggestionsJSON(&shown) ==
             "{\"x\":10,\"y\":20,\"width\":240,\"height\":32,\"rtl\":false,\"selected\":-1,\"rows\":["
             "{\"kind\":0,\"type\":21,\"main\":\"ada@example.com\",\"minor\":\"\",\"label\":\"\xE2\x80\xA2\xE2\x80\xA2"
             "\xE2\x80\xA2\",\"voice_over\":\"\",\"selectable\":true,\"acceptable\":true,\"loading\":false},"
             "{\"kind\":1,\"type\":4,\"main\":\"\",\"minor\":\"\",\"label\":\"\",\"voice_over\":\"\",\"selectable\":false,"
             "\"acceptable\":false,\"loading\":false},"
             "{\"kind\":3,\"type\":26,\"main\":\"Manage passwords\xE2\x80\xA6\",\"minor\":\"\",\"label\":\"\","
             "\"voice_over\":\"\",\"selectable\":true,\"acceptable\":true,\"loading\":false}]}",
         "entry, separator and footer rows go whole, UTF-8 as it is");

  const ForkSuggestionRow quoted[] = {{0, 0, "say \"hi\"\\", nullptr, "line 1\nline 2", "\x01", 1, 1, 1}};
  shown = Shown(quoted, 1);
  shown.rtl = 1;
  shown.selected = 0;
  Expect(SuggestionsJSON(&shown) ==
             "{\"x\":10,\"y\":20,\"width\":240,\"height\":32,\"rtl\":true,\"selected\":0,\"rows\":["
             "{\"kind\":0,\"type\":0,\"main\":\"say \\\"hi\\\"\\\\\",\"minor\":\"\",\"label\":\"line 1\\u000aline 2\","
             "\"voice_over\":\"\\u0001\",\"selectable\":true,\"acceptable\":true,\"loading\":true}]}",
         "quotes, backslashes and control characters are escaped; a NULL string is empty");

  shown = Shown(password, 1);
  shown.selected = 5;
  Expect(SuggestionsJSON(&shown).find("\"selected\":-1") != std::string::npos, "a selection past the rows is none");

  std::vector<ForkSuggestionRow> many(cmux_shim::kMaxSuggestionRows + 50, password[0]);
  shown = Shown(many.data(), static_cast<int>(many.size()));
  const std::string capped = SuggestionsJSON(&shown);
  size_t rows = 0;
  for (size_t at = capped.find("\"kind\""); at != std::string::npos; at = capped.find("\"kind\"", at + 1)) ++rows;
  Expect(rows == static_cast<size_t>(cmux_shim::kMaxSuggestionRows), "at most kMaxSuggestionRows rows go");

  shown = Shown(password, 0);
  Expect(SuggestionsJSON(&shown).find("\"rows\":[]") != std::string::npos, "no rows is an empty list");

  Expect(SuggestionsJSON(nullptr).empty(), "no struct sends nothing");
  shown = Shown(password, 3);
  shown.size = static_cast<int>(offsetof(cmux_shim::ForkSuggestions, row_count));
  Expect(SuggestionsJSON(&shown).empty(), "a struct older than API 31's first layout sends nothing");
  shown = Shown(nullptr, 2);
  Expect(SuggestionsJSON(&shown).empty(), "rows without data send nothing");
  shown = Shown(password, -1);
  Expect(SuggestionsJSON(&shown).empty(), "a negative row count sends nothing");

  if (failures == 0) std::printf("suggestion_rows_test: ok\n");
  return failures == 0 ? 0 : 1;
}
