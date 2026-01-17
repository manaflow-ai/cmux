import { X, Image as ImageIcon } from "lucide-react";
import { useState, useCallback } from "react";
import { ImagePreviewDialog } from "./ImagePreviewDialog";

interface ImagePillboxProps {
  src: string;
  altText: string;
  fileName?: string;
  onRemove?: () => void;
}

export function ImagePillbox({
  src,
  altText,
  fileName,
  onRemove,
}: ImagePillboxProps) {
  const [isPreviewOpen, setIsPreviewOpen] = useState(false);

  const displayName = fileName || altText || "Image";
  // Truncate long filenames
  const truncatedName =
    displayName.length > 20
      ? `${displayName.slice(0, 17)}...`
      : displayName;

  const handleClick = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();
      setIsPreviewOpen(true);
    },
    []
  );

  const handleRemove = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();
      onRemove?.();
    },
    [onRemove]
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        setIsPreviewOpen(true);
      }
    },
    []
  );

  return (
    <>
      <span
        className="inline-flex items-center gap-1.5 px-2 py-1 my-0.5 mx-0.5 rounded-lg bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 text-neutral-700 dark:text-neutral-300 text-sm cursor-pointer hover:bg-neutral-200 dark:hover:bg-neutral-700 transition-colors select-none"
        onClick={handleClick}
        onKeyDown={handleKeyDown}
        role="button"
        tabIndex={0}
        title={`Click to preview: ${displayName}`}
      >
        {/* Thumbnail preview */}
        <span className="relative flex-shrink-0 w-5 h-5 rounded overflow-hidden bg-neutral-200 dark:bg-neutral-700">
          <img
            src={src}
            alt={altText}
            className="w-full h-full object-cover"
            draggable={false}
          />
        </span>

        {/* Filename */}
        <span className="truncate max-w-[120px] text-xs font-medium">
          {truncatedName}
        </span>

        {/* Image icon indicator */}
        <ImageIcon className="w-3 h-3 text-neutral-400 dark:text-neutral-500 flex-shrink-0" />

        {/* Remove button */}
        {onRemove && (
          <button
            type="button"
            onClick={handleRemove}
            className="flex-shrink-0 p-0.5 rounded-full hover:bg-neutral-300 dark:hover:bg-neutral-600 transition-colors"
            title="Remove image"
          >
            <X className="w-3 h-3" />
          </button>
        )}
      </span>

      <ImagePreviewDialog
        isOpen={isPreviewOpen}
        onClose={() => setIsPreviewOpen(false)}
        src={src}
        altText={altText}
        fileName={fileName}
      />
    </>
  );
}
