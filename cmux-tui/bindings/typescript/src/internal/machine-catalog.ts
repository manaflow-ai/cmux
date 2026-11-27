/** This chooses a response format; it never supplies a machine carrier. */
export function machineCatalogParams(catalog: boolean | undefined): Record<string, boolean> {
  if (catalog !== undefined && typeof catalog !== "boolean") throw new TypeError("catalog must be a boolean");
  return catalog === true ? { catalog: true } : {};
}
