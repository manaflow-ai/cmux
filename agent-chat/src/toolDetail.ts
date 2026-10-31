/**
 * Keep the full command available to the native browser tooltip while the
 * summary's single-line detail stays ellipsized by CSS.
 */
export function toolDetailHoverTitle(detail: string | undefined): string | undefined {
  return detail !== undefined && detail.trim().length > 0 ? detail : undefined;
}
