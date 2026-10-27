// Autofill, password and <datalist> suggestions as data (fork API 31, task
// p01-process-172; drawn by cmux, task 061), with no CEF
// (scripts/cmux-next/test-shim-suggestion-rows-cpp.sh compiles it alone).
// The Fork* structs copy include/cef_cmux.h of manaflow-ai/cef
// cp/p01-process-172 (the artifact's header is older than API 31); the
// SUGGESTIONS event carries the rows as the JSON SuggestionsJSON writes, which
// ChromiumHostSuggestions.swift reads.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

#include "unsafe_buffers.h"

namespace cmux_shim {

// cef_cmux.h's cmux_suggestion_row_t. Strings are UTF-8, "" when absent.
struct ForkSuggestionRow {
  int kind;
  int type;
  const char* main_text;
  const char* minor_text;
  const char* label;
  const char* voice_over;
  int selectable;
  int acceptable;
  int loading;
};

// cef_cmux.h's cmux_suggestions_t (fields are only appended; `size` is the
// fork's).
struct ForkSuggestions {
  int size;
  int64_t token;
  int x;
  int y;
  int width;
  int height;
  int rtl;
  int selected;
  const ForkSuggestionRow* rows;
  int row_count;
};

// cef_cmux.h's cmux_suggestion_handler_t (`size` is ours).
struct ForkSuggestionHandler {
  int size;
  void (*show)(void* context, int browser_id, const ForkSuggestions* rows);
  void (*select)(void* context, int browser_id, int64_t token, int index);
  void (*hide)(void* context, int browser_id, int64_t token);
  void (*announce)(void* context, int browser_id, const char* text);
  void* context;
};

// The most rows one SUGGESTIONS event carries (Chrome's popup shows a few
// dozen at most; a page's <datalist> can list thousands).
inline constexpr int kMaxSuggestionRows = 200;

// `text` as a JSON string literal: quotes, backslashes and control characters
// escaped, other UTF-8 bytes as they are.
inline void AppendJSONString(std::string* out, const char* text) {
  constexpr std::string_view kHex = "0123456789abcdef";
  out->push_back('"');
  for (const char byte : std::string_view(text ? text : "")) {
    const unsigned char c = static_cast<unsigned char>(byte);
    if (c == '"' || c == '\\') {
      out->push_back('\\');
      out->push_back(static_cast<char>(c));
    } else if (c < 0x20) {
      out->append("\\u00");
      out->push_back(kHex[c >> 4]);
      out->push_back(kHex[c & 0xf]);
    } else {
      out->push_back(static_cast<char>(c));
    }
  }
  out->push_back('"');
}

// The SUGGESTIONS show event's s1: {"x","y","width","height","rtl",
// "selected","rows":[{"kind","type","main","minor","label","voice_over",
// "selectable","acceptable","loading"}]}, at most kMaxSuggestionRows rows.
// "" when the fork's struct is older than API 31's first layout or its rows
// are missing.
inline std::string SuggestionsJSON(const ForkSuggestions* suggestions) {
  if (!suggestions || suggestions->size < static_cast<int>(offsetof(ForkSuggestions, row_count) + sizeof(int)) ||
      suggestions->row_count < 0 || (suggestions->row_count > 0 && !suggestions->rows)) {
    return std::string();
  }
  const int count = suggestions->row_count < kMaxSuggestionRows ? suggestions->row_count : kMaxSuggestionRows;
  const int selected = suggestions->selected < count ? suggestions->selected : -1;
  std::string json = "{\"x\":" + std::to_string(suggestions->x) + ",\"y\":" + std::to_string(suggestions->y) +
                     ",\"width\":" + std::to_string(suggestions->width) +
                     ",\"height\":" + std::to_string(suggestions->height) +
                     ",\"rtl\":" + (suggestions->rtl ? "true" : "false") + ",\"selected\":" +
                     std::to_string(selected < 0 ? -1 : selected) + ",\"rows\":[";
  // SAFETY: the fork's cmux_suggestions_t holds `row_count` rows at `rows`,
  // alive for the show call; the checks above refused a negative count and
  // NULL rows with a count.
  const auto all = UNSAFE_BUFFERS(SpanFromCArray(suggestions->rows, suggestions->row_count));
  bool first = true;
  for (const ForkSuggestionRow& row : all.first(static_cast<size_t>(count))) {
    if (!first) json.push_back(',');
    first = false;
    json += "{\"kind\":" + std::to_string(row.kind) + ",\"type\":" + std::to_string(row.type) + ",\"main\":";
    AppendJSONString(&json, row.main_text);
    json += ",\"minor\":";
    AppendJSONString(&json, row.minor_text);
    json += ",\"label\":";
    AppendJSONString(&json, row.label);
    json += ",\"voice_over\":";
    AppendJSONString(&json, row.voice_over);
    json += std::string(",\"selectable\":") + (row.selectable ? "true" : "false") +
            ",\"acceptable\":" + (row.acceptable ? "true" : "false") + ",\"loading\":" +
            (row.loading ? "true" : "false") + "}";
  }
  json += "]}";
  return json;
}

}  // namespace cmux_shim
