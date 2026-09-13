// JNI bridge between GhosttyTerminal.kt and libghostty-vt's C API.
//
// Terminal mutation only happens through ghostty_terminal_vt_write() (there is
// no structured cell-setter API), so the Kotlin side synthesizes VT bytes from
// the Mac's render_grid snapshots and feeds them here. Reading state back out
// uses the render-state row/cell iterators (not grid_ref, which the ghostty
// headers document as unsuitable for a real-time render loop) and is packed
// into a single flat byte buffer per call to minimize JNI boundary crossings —
// see GhosttyRenderSnapshot.kt for the exact layout this buffer decodes into.

#include <jni.h>
#include <cstdint>
#include <cstring>
#include <vector>

#include <ghostty/vt.h>

namespace {

void appendU8(std::vector<uint8_t>& buf, uint8_t v) {
    buf.push_back(v);
}

void appendI32(std::vector<uint8_t>& buf, int32_t v) {
    buf.push_back(static_cast<uint8_t>(v & 0xFF));
    buf.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    buf.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
    buf.push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
}

void appendU32(std::vector<uint8_t>& buf, uint32_t v) {
    appendI32(buf, static_cast<int32_t>(v));
}

void appendRgb(std::vector<uint8_t>& buf, GhosttyColorRgb rgb) {
    buf.push_back(rgb.r);
    buf.push_back(rgb.g);
    buf.push_back(rgb.b);
}

uint8_t styleFlagsByte(const GhosttyStyle& style) {
    uint8_t flags = 0;
    if (style.bold) flags |= 1u << 0;
    if (style.italic) flags |= 1u << 1;
    if (style.faint) flags |= 1u << 2;
    if (style.blink) flags |= 1u << 3;
    if (style.inverse) flags |= 1u << 4;
    if (style.invisible) flags |= 1u << 5;
    if (style.strikethrough) flags |= 1u << 6;
    if (style.overline) flags |= 1u << 7;
    return flags;
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeNewTerminal(
    JNIEnv* env, jobject /*thiz*/, jint cols, jint rows, jlong maxScrollback) {
    GhosttyTerminal terminal = nullptr;
    GhosttyTerminalOptions options{};
    options.cols = static_cast<uint16_t>(cols);
    options.rows = static_cast<uint16_t>(rows);
    options.max_scrollback = static_cast<size_t>(maxScrollback);
    if (ghostty_terminal_new(nullptr, &terminal, options) != GHOSTTY_SUCCESS) {
        return 0;
    }
    return reinterpret_cast<jlong>(terminal);
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeFreeTerminal(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr) {
    if (terminalPtr == 0) return;
    ghostty_terminal_free(reinterpret_cast<GhosttyTerminal>(terminalPtr));
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeReset(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr) {
    if (terminalPtr == 0) return;
    ghostty_terminal_reset(reinterpret_cast<GhosttyTerminal>(terminalPtr));
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeResize(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr, jint cols, jint rows) {
    if (terminalPtr == 0) return;
    ghostty_terminal_resize(
        reinterpret_cast<GhosttyTerminal>(terminalPtr),
        static_cast<uint16_t>(cols),
        static_cast<uint16_t>(rows),
        0, 0);
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeScrollViewportDelta(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr, jint deltaRows) {
    if (terminalPtr == 0) return;
    GhosttyTerminalScrollViewport behavior{};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
    behavior.value.delta = static_cast<intptr_t>(deltaRows);
    ghostty_terminal_scroll_viewport(reinterpret_cast<GhosttyTerminal>(terminalPtr), behavior);
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeScrollViewportToBottom(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr) {
    if (terminalPtr == 0) return;
    GhosttyTerminalScrollViewport behavior{};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
    ghostty_terminal_scroll_viewport(reinterpret_cast<GhosttyTerminal>(terminalPtr), behavior);
}

JNIEXPORT jboolean JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeIsViewportActive(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr) {
    if (terminalPtr == 0) return JNI_TRUE;
    bool active = true;
    ghostty_terminal_get(
        reinterpret_cast<GhosttyTerminal>(terminalPtr),
        GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE,
        &active);
    return active ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeScrollOffset(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr) {
    if (terminalPtr == 0) return 0;
    GhosttyTerminalScrollbar scrollbar{};
    ghostty_terminal_get(
        reinterpret_cast<GhosttyTerminal>(terminalPtr),
        GHOSTTY_TERMINAL_DATA_SCROLLBAR,
        &scrollbar);
    return static_cast<jlong>(scrollbar.offset);
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeScrollViewportToRow(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr, jlong row) {
    if (terminalPtr == 0) return;
    GhosttyTerminalScrollViewport behavior{};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW;
    behavior.value.row = static_cast<size_t>(row);
    ghostty_terminal_scroll_viewport(reinterpret_cast<GhosttyTerminal>(terminalPtr), behavior);
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeVtWrite(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr, jbyteArray data) {
    if (terminalPtr == 0 || data == nullptr) return;
    jsize len = env->GetArrayLength(data);
    if (len <= 0) return;
    std::vector<uint8_t> bytes(static_cast<size_t>(len));
    env->GetByteArrayRegion(data, 0, len, reinterpret_cast<jbyte*>(bytes.data()));
    ghostty_terminal_vt_write(
        reinterpret_cast<GhosttyTerminal>(terminalPtr),
        bytes.data(),
        bytes.size());
}

JNIEXPORT jlong JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeNewRenderState(
    JNIEnv* env, jobject /*thiz*/) {
    GhosttyRenderState state = nullptr;
    if (ghostty_render_state_new(nullptr, &state) != GHOSTTY_SUCCESS) {
        return 0;
    }
    return reinterpret_cast<jlong>(state);
}

JNIEXPORT void JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeFreeRenderState(
    JNIEnv* env, jobject /*thiz*/, jlong renderStatePtr) {
    if (renderStatePtr == 0) return;
    ghostty_render_state_free(reinterpret_cast<GhosttyRenderState>(renderStatePtr));
}

JNIEXPORT jbyteArray JNICALL
Java_dev_cmux_android_core_ghosttyvt_GhosttyTerminal_nativeSnapshot(
    JNIEnv* env, jobject /*thiz*/, jlong terminalPtr, jlong renderStatePtr) {
    if (terminalPtr == 0 || renderStatePtr == 0) return nullptr;

    auto terminal = reinterpret_cast<GhosttyTerminal>(terminalPtr);
    auto state = reinterpret_cast<GhosttyRenderState>(renderStatePtr);

    if (ghostty_render_state_update(state, terminal) != GHOSTTY_SUCCESS) {
        return nullptr;
    }

    uint16_t cols = 0, rows = 0;
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);

    bool cursorViewportHasValue = false;
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursorViewportHasValue);
    bool cursorVisible = false;
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursorVisible);
    bool cursorBlinking = false;
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &cursorBlinking);
    GhosttyRenderStateCursorVisualStyle cursorVisualStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursorVisualStyle);
    uint16_t cursorX = 0, cursorY = 0;
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursorX);
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursorY);

    GhosttyColorRgb defaultFg{0xD4, 0xD4, 0xD4};
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &defaultFg);
    GhosttyColorRgb defaultBg{0x0D, 0x0D, 0x0D};
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &defaultBg);

    std::vector<uint8_t> buf;
    buf.reserve(64 + static_cast<size_t>(cols) * static_cast<size_t>(rows) * 14);

    appendI32(buf, cols);
    appendI32(buf, rows);
    appendU8(buf, (cursorViewportHasValue && cursorVisible) ? 1 : 0);
    appendI32(buf, cursorX);
    appendI32(buf, cursorY);
    appendU8(buf, static_cast<uint8_t>(cursorVisualStyle));
    appendU8(buf, cursorBlinking ? 1 : 0);
    appendRgb(buf, defaultFg);
    appendRgb(buf, defaultBg);

    GhosttyRenderStateRowIterator rowIter = nullptr;
    ghostty_render_state_row_iterator_new(nullptr, &rowIter);
    ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIter);

    GhosttyRenderStateRowCells cells = nullptr;
    ghostty_render_state_row_cells_new(nullptr, &cells);

    while (ghostty_render_state_row_iterator_next(rowIter)) {
        ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells);

        for (uint16_t x = 0; x < cols; x++) {
            if (!ghostty_render_state_row_cells_next(cells)) break;

            uint32_t graphemesLen = 0;
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemesLen);

            // Only the base codepoint is kept for now (combining marks are
            // dropped) — the buffer must still be sized to the full grapheme
            // length since the API writes graphemes_len codepoints into it.
            uint32_t codepoint = 0;
            if (graphemesLen > 0) {
                std::vector<uint32_t> graphemeBuf(graphemesLen, 0);
                if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, graphemeBuf.data()) == GHOSTTY_SUCCESS) {
                    codepoint = graphemeBuf[0];
                }
            }

            GhosttyColorRgb fg{};
            bool hasFg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS;
            GhosttyColorRgb bg{};
            bool hasBg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS;

            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

            appendU32(buf, codepoint);
            appendU8(buf, hasFg ? 1 : 0);
            appendRgb(buf, hasFg ? fg : GhosttyColorRgb{0, 0, 0});
            appendU8(buf, hasBg ? 1 : 0);
            appendRgb(buf, hasBg ? bg : GhosttyColorRgb{0, 0, 0});
            appendU8(buf, styleFlagsByte(style));
            appendU8(buf, static_cast<uint8_t>(style.underline));
        }
    }

    ghostty_render_state_row_cells_free(cells);
    ghostty_render_state_row_iterator_free(rowIter);

    jbyteArray result = env->NewByteArray(static_cast<jsize>(buf.size()));
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(buf.size()), reinterpret_cast<const jbyte*>(buf.data()));
    }
    return result;
}

} // extern "C"
