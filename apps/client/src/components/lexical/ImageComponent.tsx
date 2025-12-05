import { ImagePillbox } from "./ImagePillbox";

interface ImageComponentProps {
  src: string;
  altText: string;
  fileName?: string;
  nodeKey?: string;
  onRemove?: () => void;
}

export default function ImageComponent({
  src,
  altText,
  fileName,
  onRemove,
}: ImageComponentProps) {
  return (
    <ImagePillbox
      src={src}
      altText={altText}
      fileName={fileName}
      onRemove={onRemove}
    />
  );
}
