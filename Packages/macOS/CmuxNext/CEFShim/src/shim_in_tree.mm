// Fork API 36 wrappers: in-tree pages (plans/cmux-next/in-tree-pages.md). Each returns NULL, 0 or -1 when the
// fork lacks the call. UI thread only.

#include "shim_internal.h"

using namespace cmux_shim;

extern "C" {

void* cmux_shim_browser_set_in_tree_hosting(int browser_id, void* container_view) {
  if (!fork_api().browser_set_in_tree_hosting) return nullptr;
  return fork_api().browser_set_in_tree_hosting(browser_id, container_view);
}

void* cmux_shim_browser_in_tree_content_view(int browser_id) {
  if (!fork_api().browser_in_tree_content_view) return nullptr;
  return fork_api().browser_in_tree_content_view(browser_id);
}

int cmux_shim_browser_in_tree_widget_drawing(int browser_id) {
  if (!fork_api().browser_in_tree_widget_drawing) return -1;
  return fork_api().browser_in_tree_widget_drawing(browser_id);
}

}  // extern "C"
