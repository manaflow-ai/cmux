export const COMMAND_PALETTE_OPEN_EVENT = "cmux:command-palette-open";

export const requestOpenCommandPalette = () => {
  if (typeof document === "undefined") return;
  document.dispatchEvent(new Event(COMMAND_PALETTE_OPEN_EVENT));
};
